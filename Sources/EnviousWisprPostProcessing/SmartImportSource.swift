import Darwin
import EnviousWisprCore
import Foundation
import SQLite3

/// Why reading another app's vocabulary didn't work (#1686).
package enum SmartImportError: LocalizedError, Sendable, Equatable {
  case appNotFound(String)
  case unreadable(String)
  /// Spokenly only: the live preferences domain holds nothing and the only
  /// store present is the pre-migration App Store container copy. Named apart
  /// from `.unreadable` because the user has a button that fixes this, and
  /// "try quitting the app" does not (#1773).
  case legacyMigrationRequired(String)
  /// More source rows than the shared candidate ceiling, counted BEFORE the
  /// adapter's own exclusions.
  ///
  /// Distinct from `ImportFileError.tooManyWords`, whose copy says "That file"
  /// and "split it into smaller files" — both false for a competitor's
  /// database, and which would call deleted rows and snippets "words".
  case tooManySourceEntries(appName: String, limit: Int)

  package var errorDescription: String? {
    switch self {
    case .appNotFound(let app):
      return String(
        localized: "Couldn't find any \(app) words on this Mac.",
        comment: "Import from another dictation app: an error. %@ is that app's name.")
    case .unreadable(let app):
      // "can help", not "the cause": every reader failure lands here, including a store the
      // rival app is not touching (#3032 hit it with Wispr Flow quit), a malformed JSON file
      // and a schema drift. The remedy is kept for the one case it fits and is no longer
      // asserted as the reason. Shared by all eight word adapters; founder decision 2026-09-18.
      return String(
        localized:
          "Couldn't read your \(app) words, so nothing was imported. If \(app) is running, quitting it and trying again can help.",
        comment:
          "Import from another dictation app: an error. %@ is that app's name; both %@ are the same name."
      )
    case .legacyMigrationRequired(let app):
      return String(
        localized:
          "\(app)'s older App Store data can't be imported directly yet. In \(app), choose Migrate Settings from App Store Version, then try again.",
        comment:
          "Import from another dictation app: an error. %@ is that app's name; both %@ are the same name. Migrate Settings from App Store Version is that app's own menu command; keep it in English."
      )
    case .tooManySourceEntries(let app, let limit):
      return String(
        localized:
          "\(app) has more than \(String(limit)) dictionary entries, including entries it may hide or disable. EnviousWispr stopped without importing anything.",
        comment:
          "Import from another dictation app: an error. the first %@ is that app's name, the second the entry limit."
      )
    }
  }
}

/// Where a competitor app keeps a store on disk, and whether it is there.
///
/// The one thing the word adapters (`SmartImportAdapter`) and the snippet
/// adapters (`SnippetImportAppAdapter`, #2997) share below the read itself:
/// probe the candidate locations in order and report the first that exists.
package protocol ImportedAppLocator: Sendable {
  /// Where this app keeps the store, in probe order.
  var candidatePaths: [URL] { get }
}

extension ImportedAppLocator {
  /// The first location that actually exists, or nil.
  package var installedPath: URL? {
    candidatePaths.first { FileManager.default.fileExists(atPath: $0.path) }
  }
  package var isInstalled: Bool { installedPath != nil }
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
package protocol SmartImportAdapter: ImportedAppLocator {
  /// Stable identifier carried in the import batch for source attribution.
  /// No consumer reads it today (#2052).
  var identifier: String { get }
  /// What the user sees.
  var displayName: String { get }
  /// Read the canonical words, alongside any misspelling the source app
  /// itself records as correcting to that word.
  func loadWords(at url: URL) throws -> SmartImportReadResult
}

/// One word an adapter found, with the human-typed misspelling it corrects
/// FROM, if the source app records one. `aliases` is always an array — plural
/// because FluidVoice supplies a real list; Superwhisper and Wispr Flow only
/// ever produce at most one.
package struct SmartImportWord: Sendable, Equatable {
  package let canonical: String
  package let aliases: [String]
  /// Whether the source app records this word as case-sensitive.
  ///
  /// `.unspecified` for every source with no such concept, so nothing is
  /// claimed on their behalf. Only TypeWhisper supplies it today, from its own
  /// per-entry "Case sensitive" checkbox.
  package let caseSensitive: CustomWordsImportField<Bool>

  package init(
    canonical: String,
    aliases: [String] = [],
    caseSensitive: CustomWordsImportField<Bool> = .unspecified
  ) {
    self.canonical = canonical
    self.aliases = aliases
    self.caseSensitive = caseSensitive
  }
}

/// What an adapter read, and how much of the source it deliberately refused.
///
/// Five of the eight adapters exclude source rows on purpose — Superwhisper
/// (no usable destination), Wispr Flow (soft-deletes, snippets), TypeWhisper
/// (disabled rows, non-allowlisted entry types), Spokenly (regex rules, empty
/// replacements) and Juno (vocabulary the user did not author). Vox, Handy and
/// FluidVoice exclude nothing: their stores hold only what the user typed. Only
/// the adapter can know how many, and without that count an import that refused
/// every row is indistinguishable from a source that was empty — which is a
/// false statement to a Juno user whose 401 entries were all built-in.
package struct SmartImportReadResult: Sendable, Equatable {
  package let words: [SmartImportWord]
  /// Source rows deliberately refused, before shared normalization. A COUNT
  /// only — never the content, which would put a competitor's excluded text
  /// into our UI.
  package let excludedCount: Int

  package init(words: [SmartImportWord], excludedCount: Int = 0) {
    self.words = words
    self.excludedCount = excludedCount
  }
}

/// Up to `attempts` acquisitions; each reads twice and accepts only bytes that
/// agreed, and then only if `accept` succeeds on them.
///
/// Two adapters need exactly this and for the same reason: a competitor app can
/// rewrite its store while we read it, so bytes that merely parsed are not
/// bytes that coexisted. TypeWhisper can checkpoint its WAL between two
/// sequential part reads; Handy truncates its JSON file in place, and a read
/// spanning the rewrite can splice two generations into a document that parses
/// perfectly and describes a word list that never existed.
///
/// `accept` running INSIDE the loop is load-bearing rather than tidiness. Two
/// identical ZERO-BYTE reads agree perfectly, and Handy's truncation window
/// produces exactly that — measured, 2 zero-byte reads in 604,959 across three
/// writes. Accepting outside the loop would spend the whole budget on the first
/// attempt and then fail (#2052).
///
/// Note for a future third caller: a throw from `accept` is swallowed and
/// becomes `.unreadable`. Correct for both callers today — Handy's is a decode,
/// TypeWhisper's is the identity function and cannot throw — but an `accept`
/// that can throw something meaningful, a ceiling error say, would lose it here.
/// Errors from `read` are NOT swallowed; they propagate immediately.
private func acquireStableSnapshot<Snapshot, Accepted>(
  appName: String,
  attempts: Int,
  read: () throws -> Snapshot,
  agrees: (Snapshot, Snapshot) -> Bool,
  accept: (Snapshot) throws -> Accepted
) throws -> Accepted {
  for _ in 0..<attempts {
    let first = try read()
    let second = try read()
    guard agrees(first, second) else { continue }
    if let accepted = try? accept(first) { return accepted }
  }
  // The other app is actively writing. Refusing is the honest half, and the
  // `.unreadable` copy already tells the user to quit it and try again.
  throw SmartImportError.unreadable(appName)
}

/// The one owner of a SQLite read: open, prepare, step, verify completion,
/// finalize, close.
///
/// ACQUISITION — how the private copy being opened came to exist — is
/// deliberately NOT here. Wispr Flow clones its ~1 GB live database with APFS
/// clonefile and proves the source did not move across the clone (#3012);
/// TypeWhisper takes a bounded stable copy of its 296 KB store because it never
/// checkpoints its WAL. Those are two measured answers to one question, and
/// folding them into a single "policy" would be a false single authority. What
/// they genuinely share is the read sequence below, which takes the copy.
package enum SmartImportSQLiteReader {
  /// Step every row of a PRIVATE COPY through `mapRow`, then hand control back to the caller.
  ///
  /// Generic over the row type (#2997): the word adapters map rows to
  /// `SmartImportWord` and the snippet adapters to `SnippetImportCandidate`
  /// through the SAME open, prepare, step, verify-completion, finalize and
  /// close sequence, so a second feature reading the same databases cannot
  /// drift from the first on any of those steps.
  ///
  /// `mapRow` returning nil is an ordinary EXCLUSION and is counted; a THROW is
  /// a malformed source and refuses the whole read. Those are different things.
  ///
  /// `privateCopy` is a file the caller made and will delete, never a rival app's own store.
  /// It is opened READ-WRITE, deliberately, and the copy is what makes that safe. A database
  /// whose header says WAL needs a `-shm` wal-index before it can be read, and a strictly
  /// read-only connection may not create one, so a store left in WAL mode with its sidecars
  /// removed — which is how Wispr Flow rests after it quits — answered `SQLITE_CANTOPEN` at
  /// prepare under the old `SQLITE_OPEN_READONLY` open and the import told the user to quit an
  /// app that was not running (#3032; measured on macOS SQLite 3.54.0). Read-write lets SQLite
  /// build the wal-index beside the copy. Two things keep that honest:
  ///
  /// - NO `SQLITE_OPEN_CREATE`, so a missing copy still fails instead of silently becoming an
  ///   empty database that would import as "nothing found".
  /// - `PRAGMA query_only=ON` immediately after the open, so the connection can still recover
  ///   the WAL but a caller-supplied statement cannot change a row: a stray `DELETE` answers
  ///   `SQLITE_READONLY` instead of succeeding against the copy. A pragma that fails refuses
  ///   the read rather than continuing writable.
  ///
  /// NOT `immutable=1`, which looks like the read-only-safe answer and is not: it skips WAL
  /// processing entirely, so a copy whose `-wal` holds committed frames reads as though the
  /// table were not there (measured: `no such table` against a fixture with 95 committed rows
  /// in the WAL; plan §2.5.5 for #3032).
  static func readRows<Row>(
    privateCopy: URL,
    sql: String,
    appName: String,
    mapRow: (OpaquePointer?) throws -> Row?
  ) throws -> (rows: [Row], excludedCount: Int) {
    var db: OpaquePointer?
    guard
      sqlite3_open_v2(
        fileURI(privateCopyPath: privateCopy.path), &db,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_URI, nil) == SQLITE_OK,
      let db
    else {
      sqlite3_close(db)
      throw SmartImportError.unreadable(appName)
    }
    defer { sqlite3_close(db) }

    guard sqlite3_exec(db, "PRAGMA query_only=ON", nil, nil, nil) == SQLITE_OK else {
      throw SmartImportError.unreadable(appName)
    }

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      sqlite3_finalize(statement)
      throw SmartImportError.unreadable(appName)
    }
    defer { sqlite3_finalize(statement) }

    var rows: [Row] = []
    var excludedCount = 0
    var result = sqlite3_step(statement)
    while result == SQLITE_ROW {
      if let row = try mapRow(statement) { rows.append(row) } else { excludedCount += 1 }
      result = sqlite3_step(statement)
    }
    // Only SQLITE_DONE means "that was all of them" (code review, #1686). The
    // first version treated every non-ROW result as the end, so SQLITE_BUSY on
    // a database the other app was writing — or IOERR, or CORRUPT — returned
    // whatever prefix had been read, possibly nothing, and reported success. A
    // partial read presented as a complete one is the same false-pass shape as
    // a test that never runs.
    guard result == SQLITE_DONE else { throw SmartImportError.unreadable(appName) }
    return (rows, excludedCount)
  }

  /// The canonical "a corrected spelling is the word, the misspelling that
  /// prompted it is the alias" mapping (#1706), shared because Wispr Flow and
  /// TypeWhisper encode exactly that under different column names.
  static func word(
    canonical: String?,
    alias: String,
    caseSensitive: CustomWordsImportField<Bool> = .unspecified
  ) -> SmartImportWord {
    // `.whitespacesAndNewlines` also strips tabs and newlines, unlike the
    // ASCII-space-only SQL `TRIM()` this replaced.
    let trimmed = canonical?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let trimmed, !trimmed.isEmpty {
      return SmartImportWord(canonical: trimmed, aliases: [alias], caseSensitive: caseSensitive)
    }
    return SmartImportWord(canonical: alias, caseSensitive: caseSensitive)
  }

  /// A SQLite `file:` URI whose PATH is percent-encoded, so a home directory or a scratch
  /// path containing `%`, `#`, `?` or a space cannot be read as a percent escape, a query, or a
  /// fragment: SQLite percent-decodes the path, so an unescaped `%` or `#` resolves to a
  /// different file (#2997). `.urlPathAllowed` keeps `/` and every ordinary path character and
  /// encodes exactly those three plus space; SQLite decodes them back to the real path.
  ///
  /// Private, and the mode is fixed here rather than passed in: a caller cannot spell
  /// `mode=ro` again and reintroduce #3032, and `mode=rw` (no `c`) refuses to create a missing
  /// file for the same reason the open flags omit `SQLITE_OPEN_CREATE`.
  private static func fileURI(privateCopyPath path: String) -> String {
    let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
    return "file:\(encoded)?mode=rw"
  }

  // MARK: - Strict column reads
  //
  // SQLite columns are dynamically typed, so a schema that drifts under us can
  // hand back an INTEGER where text belongs, or NULL where a value must exist.
  // Converting those silently turns a malformed source into plausible-looking
  // words. Malformed STRUCTURE refuses the whole read; valid-but-incompatible
  // CONTENT is a nil from the mapper and gets counted.

  static func requiredText(
    _ statement: OpaquePointer?, _ column: Int32, _ appName: String
  ) throws -> String {
    guard sqlite3_column_type(statement, column) == SQLITE_TEXT,
      let value = sqlite3_column_text(statement, column)
    else { throw SmartImportError.unreadable(appName) }
    return try decodeText(value, sqlite3_column_bytes(statement, column), appName)
  }

  static func optionalText(
    _ statement: OpaquePointer?, _ column: Int32, _ appName: String
  ) throws -> String? {
    let type = sqlite3_column_type(statement, column)
    guard type != SQLITE_NULL else { return nil }
    guard type == SQLITE_TEXT, let value = sqlite3_column_text(statement, column) else {
      throw SmartImportError.unreadable(appName)
    }
    return try decodeText(value, sqlite3_column_bytes(statement, column), appName)
  }

  /// UTF-8 text of the column's EXACT stored length, refusing an embedded NUL. `String(cString:)`
  /// stops at the first NUL byte, so a value the source stored as `a\0b` would import as `a`
  /// and be reported a success (#2997). Malformed bytes and a NUL both refuse the whole read,
  /// consistent with the strict-column policy above.
  private static func decodeText(
    _ value: UnsafePointer<UInt8>, _ byteCount: Int32, _ appName: String
  ) throws -> String {
    let bytes = UnsafeBufferPointer(start: value, count: Int(byteCount))
    guard let text = String(bytes: bytes, encoding: .utf8), !text.utf8.contains(0) else {
      throw SmartImportError.unreadable(appName)
    }
    return text
  }

  static func requiredBoolean(
    _ statement: OpaquePointer?, _ column: Int32, _ appName: String
  ) throws -> Bool {
    guard sqlite3_column_type(statement, column) == SQLITE_INTEGER else {
      throw SmartImportError.unreadable(appName)
    }
    switch sqlite3_column_int(statement, column) {
    case 0: return false
    case 1: return true
    default: throw SmartImportError.unreadable(appName)
    }
  }
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
    // Mechanics shared through `BoundedFileRead` (#2997); this site's contract is
    // unchanged: any reader failure and any overflow are `.unreadable(appName)`, and the
    // loop never checked cancellation here, so the hook is empty rather than the default.
    let data: Data
    do {
      data = try BoundedFileRead.read(
        at: url, ceiling: Self.maximumVocabularyBytes, beforeEachRead: {})
    } catch is BoundedFileRead.Failure {
      throw SmartImportError.unreadable(appName)
    }
    guard data.count <= Self.maximumVocabularyBytes else {
      throw SmartImportError.unreadable(appName)
    }
    return data
  }
}

// MARK: - FluidVoice

/// Single JSON file. The keys beside `terms` are FluidVoice's own ASR tuning
/// parameters, not vocabulary, and are ignored.
package struct FluidVoiceAdapter: SmartImportAdapter {
  package let identifier = "fluidvoice"
  package let displayName = "FluidVoice"

  private struct Vocabulary: Decodable {
    struct Term: Decodable {
      let text: String
      let aliases: [String]?
    }
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

  package func loadWords(at url: URL) throws -> SmartImportReadResult {
    let data = try boundedData(at: url, appName: displayName)
    guard let vocabulary = try? JSONDecoder().decode(Vocabulary.self, from: data) else {
      throw SmartImportError.unreadable(displayName)
    }
    // `terms` absent entirely is a legitimate fresh install, not a failure.
    // FluidVoice excludes nothing: every term it stores is one the user added.
    return SmartImportReadResult(
      words: (vocabulary.terms ?? []).map {
        SmartImportWord(canonical: $0.text, aliases: $0.aliases ?? [])
      })
  }
}

// MARK: - Superwhisper

/// JSON settings file in one of two locations. Both keys may be absent
/// entirely on a fresh install rather than present-but-empty.
package struct SuperwhisperAdapter: SmartImportAdapter {
  package let identifier = "superwhisper"
  package let displayName = "Superwhisper"

  private struct Settings: Decodable {
    struct Replacement: Decodable {
      let with: String?
      let original: String?
    }
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

  package func loadWords(at url: URL) throws -> SmartImportReadResult {
    let data = try boundedData(at: url, appName: displayName)
    guard let settings = try? JSONDecoder().decode(Settings.self, from: data) else {
      throw SmartImportError.unreadable(displayName)
    }
    // A replacement is a find/replace pair; its `with` side is the spelling
    // the user actually wants, which is the word worth bringing across; its
    // `original` side, when present, is the misspelling that prompted it.
    let plain = (settings.vocabulary ?? []).map { SmartImportWord(canonical: $0) }
    var corrected: [SmartImportWord] = []
    var excludedCount = 0
    for replacement in settings.replacements ?? [] {
      // A replacement with no destination has no word in it. It was always
      // dropped here; #1773 only started COUNTING it, so a Superwhisper file
      // holding nothing but blank replacements stops reporting as "no words
      // found" and says what it actually did.
      guard let with = replacement.with?.trimmingCharacters(in: .whitespacesAndNewlines),
        !with.isEmpty
      else {
        excludedCount += 1
        continue
      }
      let alias = replacement.original?.trimmingCharacters(in: .whitespacesAndNewlines)
      corrected.append(
        SmartImportWord(canonical: with, aliases: (alias?.isEmpty == false) ? [alias!] : []))
    }
    return SmartImportReadResult(words: plain + corrected, excludedCount: excludedCount)
  }
}

// MARK: - Wispr Flow

/// How Wispr Flow's database is read, shared by the word adapter and the snippet
/// adapter (#2997, #3012, #3032). Its store has three observed shapes: a
/// delete-mode header with no sidecars, a WAL header with `-wal` and `-shm`, and
/// a WAL header with no sidecars after quitting. The earlier "refuse whenever a
/// sidecar exists, else open `immutable=1`" policy refused the running shape and
/// could silently ignore committed WAL content.
///
/// Instead we read a private APFS clone: clone the main file plus any `-wal` into
/// a same-volume scratch directory, prove the source did not change across the
/// clone, then hand the clone to `SmartImportSQLiteReader`, which opens it read-write
/// under `PRAGMA query_only` so SQLite can build the `-shm` wal-index beside OUR copy
/// (a read-only open could not, and refused the founder's quit-and-checkpointed store,
/// #3032). This works whether Wispr Flow is open or closed and never writes into
/// Wispr Flow's directory. What differs per adapter is the SQL and the row mapping,
/// which are passed in.
package enum WisprFlowDatabase {
  /// The one database, holding words and snippets alike.
  static var candidatePaths: [URL] {
    [
      FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Wispr Flow/flow.sqlite")
    ]
  }

  /// The parts whose presence and identity must be stable for a clone to be
  /// trusted. We CLONE only main and `-wal`; `-shm` is a regenerable wal-index
  /// SQLite rebuilds beside the clone, and a `-journal` (rollback mode) makes the
  /// main file mid-transaction, which this read cannot recover — so its presence
  /// makes acquisition unavailable rather than something to clone.
  private static let monitoredSuffixes = ["", "-wal", "-shm", "-journal"]
  private static let clonedSuffixes = ["", "-wal"]
  private static let acquisitionAttempts = 3

  /// One monitored part's identity, or its explicit absence. Identity is inode +
  /// size + nanosecond mtime + nanosecond ctime: a replacement changes the inode,
  /// an append/truncate the size, and any in-place write the nanosecond ctime, so
  /// a checkpoint or write during the clone window cannot pass unnoticed.
  private enum PartState: Equatable {
    case absent
    case present(
      inode: UInt64, size: Int64, mtimeSec: Int, mtimeNsec: Int, ctimeSec: Int, ctimeNsec: Int)
  }

  /// The source's metadata across every monitored part, or an explicitly
  /// unavailable acquisition state (main missing, a rollback `-journal` present,
  /// or a metadata read that failed for any reason other than a part being
  /// absent). `agrees` rejects `.unavailable` even when both reads return it, so
  /// such a source retries and then exhausts to `.unreadable` rather than being
  /// read.
  private enum SourceMetadata: Equatable {
    case unavailable
    case available([PartState])
  }

  /// Read `sql` against a stable private clone of the database at `url`. `mapRow`
  /// returning nil is an exclusion and is counted; a throw refuses the whole read
  /// (`SmartImportSQLiteReader.readRows`).
  static func read<Row>(
    at url: URL,
    appName: String,
    sql: String,
    mapRow: (OpaquePointer?) throws -> Row?
  ) throws -> (rows: [Row], excludedCount: Int) {
    let fm = FileManager.default
    // `.itemReplacementDirectory` is created on the SAME volume as `url`, which
    // is what makes the clone below an APFS clonefile rather than a physical
    // copy. Same-volume placement does not by itself PROVE a clone, so the clone
    // is still forced (`COPYFILE_CLONE_FORCE`) and a failure refuses the read.
    let scratchParent: URL
    do {
      scratchParent = try fm.url(
        for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
    } catch {
      throw SmartImportError.unreadable(appName)
    }
    defer { try? fm.removeItem(at: scratchParent) }

    let copyMain = try acquireStableClone(source: url, into: scratchParent, appName: appName)

    // The clone is private and cannot change under us, so there is no live-file
    // window left to guard after the read.
    return try SmartImportSQLiteReader.readRows(
      privateCopy: copyMain, sql: sql, appName: appName, mapRow: mapRow)
  }

  /// Acquire a byte-stable clone of main (+ `-wal`) via the shared retry loop.
  /// `read` never throws for a retryable condition — it returns `.unavailable`,
  /// which `agrees` rejects — so a briefly-busy source retries and then exhausts
  /// to `.unreadable`. `accept` clones into a fresh empty subdirectory, then
  /// re-reads the source metadata and refuses unless it is byte-identical to the
  /// accepted view, closing the window in which Wispr Flow could checkpoint
  /// between cloning main and `-wal`.
  private static func acquireStableClone(
    source: URL, into scratchParent: URL, appName: String
  ) throws -> URL {
    typealias Meta = SourceMetadata
    let read: () throws -> Meta = { readSourceMetadata(source: source) }
    let agrees: (Meta, Meta) -> Bool = { first, second in
      if case .available = first { return first == second }
      return false
    }
    let accept: (Meta) throws -> URL = { accepted in
      let fm = FileManager.default
      let dir = scratchParent.appendingPathComponent(UUID().uuidString, isDirectory: true)
      guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else {
        throw SmartImportError.unreadable(appName)
      }
      var kept = false
      defer { if !kept { try? fm.removeItem(at: dir) } }

      let copyMain = dir.appendingPathComponent(source.lastPathComponent)
      for suffix in Self.clonedSuffixes {
        let src = source.path + suffix
        guard fm.fileExists(atPath: src) else {
          // Only main is required; `-wal` is optional (absent in delete mode).
          if suffix.isEmpty { throw SmartImportError.unreadable(appName) }
          continue
        }
        guard cloneFile(from: src, to: copyMain.path + suffix) else {
          throw SmartImportError.unreadable(appName)
        }
        // Defence in depth: the clone of a regular source must itself be a regular file, so
        // nothing SQLite opens can be a link back out of the scratch directory (#3012).
        var cloned = stat()
        guard lstat(copyMain.path + suffix, &cloned) == 0,
          (cloned.st_mode & S_IFMT) == S_IFREG
        else {
          throw SmartImportError.unreadable(appName)
        }
      }
      // The source must not have changed while we cloned it.
      guard readSourceMetadata(source: source) == accepted else {
        throw SmartImportError.unreadable(appName)
      }
      kept = true
      return copyMain
    }
    return try acquireStableSnapshot(
      appName: appName, attempts: Self.acquisitionAttempts,
      read: read, agrees: agrees, accept: accept)
  }

  /// Stat every monitored part. A present `-journal` or a stat failure that is
  /// not `ENOENT` makes the whole source unavailable; a missing main does too.
  private static func readSourceMetadata(source: URL) -> SourceMetadata {
    var states: [PartState] = []
    for suffix in monitoredSuffixes {
      let path = source.path + suffix
      var info = stat()
      if lstat(path, &info) != 0 {
        if errno == ENOENT {
          if suffix.isEmpty { return .unavailable }  // main gone
          states.append(.absent)
          continue
        }
        return .unavailable  // a real stat failure is not "absent"
      }
      if suffix == "-journal" { return .unavailable }  // rollback mode mid-transaction
      // Only a regular file may be cloned. A symlink (lstat reports the link) would be
      // cloned AS a link by `COPYFILE_CLONE_FORCE` (NOFOLLOW), and SQLite would then follow
      // it back to the live original, defeating the private-copy guarantee and letting it
      // touch the source's sidecars (second-pass review, #3012).
      guard (info.st_mode & S_IFMT) == S_IFREG else { return .unavailable }
      states.append(
        .present(
          inode: UInt64(info.st_ino),
          size: Int64(info.st_size),
          mtimeSec: info.st_mtimespec.tv_sec, mtimeNsec: info.st_mtimespec.tv_nsec,
          ctimeSec: info.st_ctimespec.tv_sec, ctimeNsec: info.st_ctimespec.tv_nsec))
    }
    return .available(states)
  }

  /// Clone `src` to `dst` with no physical-copy fallback: `COPYFILE_CLONE_FORCE`
  /// fails rather than copying when the destination cannot be a copy-on-write
  /// clone (e.g. a non-APFS home volume), so a 946 MB file is never silently
  /// duplicated. `dst` must not already exist (the flag sets `COPYFILE_EXCL`).
  private static func cloneFile(from src: String, to dst: String) -> Bool {
    src.withCString { s in
      dst.withCString { d in
        copyfile(s, d, nil, copyfile_flags_t(COPYFILE_CLONE_FORCE)) == 0
      }
    }
  }
}

/// SQLite, read strictly read-only against another app's live database.
package struct WisprFlowAdapter: SmartImportAdapter {
  package let identifier = "wispr-flow"
  package let displayName = "Wispr Flow"

  package var candidatePaths: [URL] { WisprFlowDatabase.candidatePaths }

  package init() {}

  package func loadWords(at url: URL) throws -> SmartImportReadResult {
    // isDeleted: a soft-delete flag. Importing unfiltered would resurrect
    // words the user deliberately removed — the single worst thing this
    // adapter could do.
    // isSnippet: text expansions are a different feature, not vocabulary.
    // `replacement` is the corrected spelling when present; `phrase` is the
    // misspelling that prompted it, carried across as an alias.
    //
    // `ORDER BY id` is new: a bare `LIMIT` with no order leaves SQLite's row
    // order unspecified, and "the same word claimed as an alias by two
    // different corrected spellings" needs a real, stable "earlier" for that
    // to mean anything. `id` (VARCHAR(36) PRIMARY KEY) is ordered, not
    // `rowid` — this table's PK does not alias `rowid`, and an unaliased
    // `rowid` is not guaranteed persistent across a `VACUUM`.
    //
    // Both filters moved OUT of the WHERE clause in #1773: an adapter cannot
    // count rows SQL never returns, and without that count an import that
    // refused everything looks identical to an empty source. The consequence
    // is deliberate — `LIMIT` now bounds TOTAL rows rather than surviving
    // ones, so a dictionary above the ceiling is refused rather than silently
    // importing whichever survivors happened to fit.
    let sql = """
      SELECT phrase, replacement, isDeleted, isSnippet
      FROM Dictionary
      ORDER BY id COLLATE BINARY ASC
      LIMIT \(CustomWordsImportLimits.maximumCandidates + 1)
      """

    // Acquisition, stable cloning, and the shared query-only read live in
    // `WisprFlowDatabase.read`, shared with the snippet adapter (#2997, #3012, #3032).
    // Only the SQL and row mapping belong to this adapter.
    let read = try WisprFlowDatabase.read(at: url, appName: displayName, sql: sql) {
      statement -> SmartImportWord? in
      let phrase = try SmartImportSQLiteReader.requiredText(statement, 0, displayName)
      let replacement = try SmartImportSQLiteReader.optionalText(statement, 1, displayName)
      let isDeleted = try SmartImportSQLiteReader.requiredBoolean(statement, 2, displayName)
      let isSnippet = try SmartImportSQLiteReader.requiredBoolean(statement, 3, displayName)
      // Both exclusions are this adapter's whole point, and both are now
      // COUNTED rather than hidden by SQL. Returning nil is an exclusion;
      // a throw above is a malformed database.
      guard !isDeleted, !isSnippet else { return nil }
      return SmartImportSQLiteReader.word(canonical: replacement, alias: phrase)
    }
    return SmartImportReadResult(words: read.rows, excludedCount: read.excludedCount)
  }
}

// MARK: - Vox

/// Single JSON settings file. `dictionary` is a flat list of terms with no
/// alias concept — structurally FluidVoice minus its alias array.
package struct VoxAdapter: SmartImportAdapter {
  package let identifier = "vox"
  package let displayName = "Vox"

  private struct Settings: Decodable {
    let dictionary: [String]?
  }

  package var candidatePaths: [URL] {
    [
      FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.vox.app/vox-settings.json")
    ]
  }

  package init() {}

  package func loadWords(at url: URL) throws -> SmartImportReadResult {
    let data = try boundedData(at: url, appName: displayName)
    guard let settings = try? JSONDecoder().decode(Settings.self, from: data) else {
      throw SmartImportError.unreadable(displayName)
    }
    // `dictionary` absent entirely is a legitimate fresh install, not a
    // failure — the treatment FluidVoice's `terms` already gets.
    //
    // Every other key in this file is ignored, and `context` deliberately so:
    // it is a free-text paragraph the user writes about themselves for Vox's
    // polish step, not vocabulary, and importing it would drop a whole
    // sentence into the custom-words list.
    return SmartImportReadResult(
      words: (settings.dictionary ?? []).map { SmartImportWord(canonical: $0) })
  }
}

// MARK: - TypeWhisper

/// How a TypeWhisper Core Data store is read: through a private,
/// stability-checked copy. Shared by the word adapter (`dictionary.store`) and
/// the snippet adapter (`snippets.store`, #2997); the two stores sit beside
/// each other with the same `-wal`/`-shm` sidecars and the same never-checkpoint
/// behaviour, so one acquisition serves both. What differs per adapter is the
/// SQL and the row mapping, which are passed in.
///
/// Both apps now share the same reader contract: open only a private copy read-write under
/// `PRAGMA query_only`. Their acquisition remains deliberately different. TypeWhisper reads
/// its bounded main and WAL bytes twice and accepts only two agreeing snapshots; Wispr Flow
/// uses a forced APFS clone because its store is roughly 1 GB.
///
/// TypeWhisper never checkpoints its WAL: after quitting, `dictionary.store-wal` can still
/// hold rows absent from main. The snapshot therefore retains both parts. `immutable=1` is
/// not an alternative because it skips WAL processing and measured 36 rows against the true
/// 38. The shared reader handles the accepted private copy without losing those rows.
///
/// The copy is also what makes this read-only in the sense a user would
/// recognise. Opening the SOURCE read-only returns the right rows too, but it
/// MODIFIES their `-shm` (verified by hash), and writing inside another app's
/// data directory is what #1686 removed.
package enum TypeWhisperStoreSnapshot {
  /// TypeWhisper keeps one Core Data store per feature beside each other
  /// (`dictionary.store`, `snippets.store`, ...), each with its own sidecars.
  static func candidatePaths(store name: String) -> [URL] {
    [
      FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/TypeWhisper/\(name)")
    ]
  }

  /// `-shm` is deliberately absent: it is a regenerable shared-memory index,
  /// not durable vocabulary. Measured — copying main+`-wal` alone still
  /// returns every row, with SQLite rebuilding the index beside the copy.
  private static let storeSuffixes = ["", "-wal"]

  /// Two passes must agree before a snapshot is used, and at most this many
  /// whole acquisitions are attempted.
  private static let acquisitionAttempts = 3

  /// The aggregate ceiling on main plus WAL. The same value the injected part
  /// reader applies per part (`TypeWhisperAdapter.readPartFromDisk`), so a
  /// part alone over the ceiling and two parts together over it are refused by
  /// one number.
  static var maximumBytes: Int { TypeWhisperAdapter.maximumVocabularyBytes }

  /// Read `sql` against a stable private copy of the store at `url`. `mapRow`
  /// returning nil is an exclusion and is counted; a throw refuses the whole
  /// read (`SmartImportSQLiteReader.readRows`).
  static func read<Row>(
    at url: URL,
    readPart: TypeWhisperAdapter.PartReader,
    appName: String,
    sql: String,
    mapRow: (OpaquePointer?) throws -> Row?
  ) throws -> (rows: [Row], excludedCount: Int) {
    let snapshot = try acquireStableSnapshot(at: url, readPart: readPart, appName: appName)

    let fm = FileManager.default
    let scratch = fm.temporaryDirectory
      .appendingPathComponent("ew-typewhisper-\(UUID().uuidString)", isDirectory: true)
    guard (try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)) != nil else {
      throw SmartImportError.unreadable(appName)
    }
    // Removed on every exit, including a throw from the read below.
    defer { try? fm.removeItem(at: scratch) }

    let copy = scratch.appendingPathComponent(url.lastPathComponent)
    for (suffix, bytes) in snapshot {
      guard (try? bytes.write(to: URL(fileURLWithPath: copy.path + suffix))) != nil else {
        throw SmartImportError.unreadable(appName)
      }
    }

    return try SmartImportSQLiteReader.readRows(
      privateCopy: copy, sql: sql, appName: appName, mapRow: mapRow)
  }

  /// Read every store part twice and accept only a byte-identical pair.
  ///
  /// Copying the parts one after another is NOT enough: TypeWhisper can
  /// checkpoint or replace the WAL between two sequential reads, producing a
  /// main file and a WAL from different moments — a snapshot that never
  /// existed. Two agreeing passes prove the accepted bytes coexisted during
  /// the overlap between them.
  ///
  /// The loop itself lives in `acquireStableSnapshot(appName:attempts:read:agrees:accept:)`,
  /// shared with Handy. Only the vendor knowledge is here: what the parts are,
  /// and what it means for two reads of them to agree.
  /// Every closure below is explicitly typed. Left to inference, the generic
  /// call takes longer than the type-checker's budget and fails to build.
  private static func acquireStableSnapshot(
    at url: URL, readPart: TypeWhisperAdapter.PartReader, appName: String
  ) throws -> [(String, Data)] {
    typealias Parts = [(String, Data)]
    let read: () throws -> Parts = {
      try readAllParts(at: url, readPart: readPart, appName: appName)
    }
    let agrees: (Parts, Parts) -> Bool = { first, second in
      first.map(\.0) == second.map(\.0)
        && zip(first, second).allSatisfy { $0.1 == $1.1 }
    }
    // Identity: TypeWhisper's acceptance is the agreement itself. The bytes are
    // opened as SQLite later, from a private copy.
    let accept: (Parts) throws -> Parts = { $0 }
    return try EnviousWisprPostProcessing.acquireStableSnapshot(
      appName: appName,
      attempts: Self.acquisitionAttempts,
      read: read,
      agrees: agrees,
      accept: accept)
  }

  private static func readAllParts(
    at url: URL, readPart: TypeWhisperAdapter.PartReader, appName: String
  ) throws -> [(String, Data)] {
    var parts: [(String, Data)] = []
    var total = 0
    for suffix in Self.storeSuffixes {
      guard let bytes = try readPart(URL(fileURLWithPath: url.path + suffix)) else { continue }
      total += bytes.count
      guard total <= Self.maximumBytes else {
        throw SmartImportError.unreadable(appName)
      }
      parts.append((suffix, bytes))
    }
    guard !parts.isEmpty else { throw SmartImportError.unreadable(appName) }
    return parts
  }
}

/// Core Data store, read through a private, stability-checked copy
/// (`TypeWhisperStoreSnapshot`, which records why that policy differs from
/// Wispr Flow's).
package struct TypeWhisperAdapter: SmartImportAdapter {
  package let identifier = "typewhisper"
  package let displayName = "TypeWhisper"

  /// Bounded read of one store part, injected so a test can mutate the WAL
  /// between the two verification passes. Returns nil when the part is absent.
  package typealias PartReader = @Sendable (URL) throws -> Data?

  private let readPart: PartReader

  package var candidatePaths: [URL] {
    TypeWhisperStoreSnapshot.candidatePaths(store: "dictionary.store")
  }

  package init(readPart: @escaping PartReader = TypeWhisperAdapter.readPartFromDisk) {
    self.readPart = readPart
  }

  /// Bounded by the shared vocabulary ceiling, applied to the bytes ACTUALLY
  /// READ rather than to a pre-read file size — a size checked before the read
  /// does not bound a file that grows during it.
  package static func readPartFromDisk(_ url: URL) throws -> Data? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    // Mechanics shared through `BoundedFileRead` (#2997). This site's contract is
    // unchanged and differs from the others on purpose: a missing part is nil, and
    // the ceiling-plus-one bytes are RETURNED, because `TypeWhisperStoreSnapshot` bounds
    // the AGGREGATE of main plus WAL and must see that a part alone already exceeds it. The
    // loop never checked cancellation here either, so the hook is empty.
    do {
      return try BoundedFileRead.read(
        at: url, ceiling: TypeWhisperAdapter.maximumVocabularyBytes, beforeEachRead: {})
    } catch is BoundedFileRead.Failure {
      throw SmartImportError.unreadable("TypeWhisper")
    }
  }

  package func loadWords(at url: URL) throws -> SmartImportReadResult {
    // No filtering WHERE clause: the mapper must SEE disabled and
    // non-allowlisted rows in order to count them.
    //
    // ZENTRYTYPE is an ALLOWLIST. Both members are observed on real rows. A
    // future third type is refused rather than guessed — TypeWhisper already
    // ships a separate snippets store, and text expansions are the one thing
    // Wispr Flow's adapter exists to exclude.
    //
    // ZSOURCERAWVALUE is deliberately not read: it is provenance, not
    // structure, so the unobserved "auto-learned" value flows down the correct
    // path instead of hitting a branch nobody wrote.
    let sql = """
      SELECT ZORIGINAL, ZREPLACEMENT, ZCASESENSITIVE, ZISENABLED, ZENTRYTYPE
      FROM ZDICTIONARYENTRY
      ORDER BY Z_PK ASC
      LIMIT \(CustomWordsImportLimits.maximumCandidates + 1)
      """

    // Acquisition (two agreeing passes over main plus WAL, a private copy, the
    // shared query-only read) is `TypeWhisperStoreSnapshot.read`, shared with
    // the snippet adapter (#2997). Only the SQL and the row mapping are this
    // adapter's.
    let read = try TypeWhisperStoreSnapshot.read(
      at: url, readPart: readPart, appName: displayName, sql: sql
    ) { statement -> SmartImportWord? in
      let original = try SmartImportSQLiteReader.requiredText(statement, 0, displayName)
      let replacement = try SmartImportSQLiteReader.optionalText(statement, 1, displayName)
      let caseSensitive = try SmartImportSQLiteReader.requiredBoolean(statement, 2, displayName)
      let isEnabled = try SmartImportSQLiteReader.requiredBoolean(statement, 3, displayName)
      let entryType = try SmartImportSQLiteReader.requiredText(statement, 4, displayName)
      guard isEnabled, entryType == "term" || entryType == "correction" else { return nil }
      // A `term` row carries the word in ZORIGINAL with ZREPLACEMENT empty; a
      // `correction` row carries the wrong spelling in ZORIGINAL and the right
      // one in ZREPLACEMENT. Reading the row STRUCTURALLY covers both without a
      // per-type branch, which is what WisprFlowAdapter already does under its
      // own column names.
      return SmartImportSQLiteReader.word(
        canonical: replacement, alias: original, caseSensitive: .supplied(caseSensitive))
    }
    return SmartImportReadResult(words: read.rows, excludedCount: read.excludedCount)
  }
}

// MARK: - Spokenly

/// Preferences-backed, read from the LIVE domain rather than the plist file.
///
/// Spokenly writes nothing to disk until it terminates — creating a
/// replacement modified no file anywhere in the home directory — so parsing
/// `~/Library/Preferences/app.spokenly.plist` returns whatever was last
/// flushed and quietly omits anything added since. Reading the domain goes
/// where the OS goes and needs no quit.
///
/// Verified to work under HARDENED RUNTIME, which matters because the dev
/// build is not hardened and the release build is, so a runtime test on the
/// dev build could never have established it: one binary, run unsigned and
/// then re-signed with `--options runtime`, returned the identical value.
package struct SpokenlyAdapter: SmartImportAdapter {
  package let identifier = "spokenly"
  package let displayName = "Spokenly"

  /// The shipping build's key. Bare `wordReplacements` is the pre-migration
  /// App Store copy, which lives in the sandboxed container.
  private static let liveKey = "wordReplacements.v2"
  private static let domain = "app.spokenly"

  /// Injected so the domain read can be driven from a test. Ordinary
  /// dependency injection of a byte source — nothing here is time-dependent,
  /// so this is NOT one of the timing seams.
  private let readDomain: @Sendable (String) -> Data?

  package init(
    readDomain: @escaping @Sendable (String) -> Data? = { key in
      UserDefaults(suiteName: SpokenlyAdapter.domain)?.data(forKey: key)
    }
  ) {
    self.readDomain = readDomain
  }

  /// Detection probes BOTH stores, current first, so the card appears for
  /// either install. Which one was found decides what `loadWords` does when
  /// the live domain is empty.
  package var candidatePaths: [URL] {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return [
      home.appendingPathComponent("Library/Preferences/app.spokenly.plist"),
      home.appendingPathComponent(
        "Library/Containers/app.spokenly/Data/Library/Preferences/app.spokenly.plist"),
    ]
  }

  private struct Rule: Decodable {
    let original: String?
    let replacement: String?
    let isRegex: Bool?
  }
  private struct Item: Decodable { let value: Rule }
  private struct Envelope: Decodable { let items: [Item]? }
  private struct Document: Decodable { let envelope: Envelope? }

  package func loadWords(at url: URL) throws -> SmartImportReadResult {
    guard let data = readDomain(Self.liveKey) else {
      // Nothing live. If the only store we found is the sandboxed container,
      // that is the pre-migration App Store copy — three weeks stale on the
      // machine this was written against. Reading a store the vendor itself
      // treats as needing migration is how an importer silently returns words
      // the user never typed and calls it success. Name the button they have
      // instead. An absent live value does NOT prove they are on the App Store
      // build, which is why this keys on which store was detected.
      let isContainerStore = url.path.contains("/Library/Containers/")
      throw isContainerStore
        ? SmartImportError.legacyMigrationRequired(displayName)
        : SmartImportError.appNotFound(displayName)
    }

    // Two guarded steps, plist value then JSON — the value is a `data` blob
    // whose contents are UTF-8 JSON, not a plist array.
    guard let document = try? JSONDecoder().decode(Document.self, from: data) else {
      throw SmartImportError.unreadable(displayName)
    }

    // `tombstones` is never parsed, and that is not a shortcut: deleting a
    // replacement REMOVES it from `items` and leaves only `{id, deletedAt}`
    // behind. Verified by creating five and deleting one. So reading `items`
    // alone cannot resurrect a word the user deleted.
    var words: [SmartImportWord] = []
    var excludedCount = 0
    for item in document.envelope?.items ?? [] {
      let rule = item.value
      // A regex rule holds a PATTERN in `original`, not a word — verified by
      // creating one through Spokenly's own Use Regular Expression checkbox.
      // An empty replacement is a delete-this-text rule with no word in it.
      let canonical = rule.replacement?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard rule.isRegex != true, !canonical.isEmpty else {
        excludedCount += 1
        continue
      }
      let alias = rule.original?.trimmingCharacters(in: .whitespacesAndNewlines)
      words.append(
        SmartImportWord(canonical: canonical, aliases: (alias?.isEmpty == false) ? [alias!] : []))
    }
    return SmartImportReadResult(words: words, excludedCount: excludedCount)
  }
}

// MARK: - Juno

/// Single JSON lexicon mixing Juno's own shipped seed vocabulary with the
/// user's. Only the latter belongs in someone's custom words.
package struct JunoAdapter: SmartImportAdapter {
  package let identifier = "juno"
  package let displayName = "Juno"

  /// The only provenance value that means "the user typed this".
  ///
  /// An ALLOWLIST rather than a denylist on the seed value, because the two
  /// directions do not fail equally: admitting an unseen machine-generated
  /// provenance puts words in the list the user never chose, while refusing an
  /// unseen user-ish one costs them a word they can retype and can see is
  /// missing. Measured on a real install: 400 of 401 rows are seeds, including
  /// bare lowercase words like `accessibility` and `dictation` that would
  /// actively bias transcription if imported.
  private static let userAuthoredSource = "user_edit"

  private struct Entry: Decodable {
    let term: String?
    let canonicalForm: String?
    let aliases: [String]?
    let source: String?

    enum CodingKeys: String, CodingKey {
      case term
      case canonicalForm = "canonical_form"
      case aliases
      case source
    }
  }

  package var candidatePaths: [URL] {
    [
      FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.juno.shell/memory/lexicon.json")
    ]
  }

  package init() {}

  package func loadWords(at url: URL) throws -> SmartImportReadResult {
    let data = try boundedData(at: url, appName: displayName)
    guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
      throw SmartImportError.unreadable(displayName)
    }
    var words: [SmartImportWord] = []
    var excludedCount = 0
    for entry in entries {
      guard entry.source == Self.userAuthoredSource else {
        excludedCount += 1
        continue
      }
      // `canonical_form` is the spelling Juno settles on; `term` is the key it
      // is filed under. They match on every observed row, but the canonical
      // form is the one that means "how this should be written".
      let canonicalForm = entry.canonicalForm?.trimmingCharacters(in: .whitespacesAndNewlines)
      let fallback = entry.term?.trimmingCharacters(in: .whitespacesAndNewlines)
      let canonical = (canonicalForm?.isEmpty == false ? canonicalForm : fallback) ?? ""
      guard !canonical.isEmpty else {
        excludedCount += 1
        continue
      }
      words.append(SmartImportWord(canonical: canonical, aliases: entry.aliases ?? []))
    }
    return SmartImportReadResult(words: words, excludedCount: excludedCount)
  }
}

// MARK: - Registry and source

// MARK: - Handy

/// One JSON file, read twice, with the word list one level down.
///
/// Handy writes `settings_store.json` IN PLACE on every settings change — the
/// inode is unchanged across writes — so there is a real window in which a
/// reader sees a truncated file. Measured on 0.9.5: 604,959 reads across three
/// writes returned 2 zero-byte files, and no partial sizes in between. Hence
/// the shared two-pass acquisition; a document that merely decodes is not a
/// document that existed, because a read spanning the rewrite can splice two
/// generations into valid JSON describing a word list nobody typed.
///
/// Nothing else about it is hard. It writes on every change rather than on
/// quit, so the app need not be closed — the file is byte-identical either side
/// of quitting — and nothing sits beside it: no WAL, no lock, no temp file.
///
/// `custom_words` is a flat `[String]` with no alias concept, the same shape as
/// Vox and TypeWhisper's Terms. Handy ships NO vocabulary of its own, verified
/// by moving the store aside and letting 0.9.5 author a fresh one: it wrote
/// `"custom_words": []`. So the Juno seed-word hazard does not apply and no
/// provenance filter is needed.
///
/// `custom_filler_words` is deliberately NOT imported. It is a REMOVAL list —
/// words the user asked Handy to strip — so importing it would add the very
/// words they asked to have taken out. Same reasoning that excludes Vox's
/// `context` paragraph.
package struct HandyAdapter: SmartImportAdapter {
  package let identifier = "handy"
  package let displayName = "Handy"

  /// Bounded read of the store, injected so a test can drive an exact
  /// torn/torn/good/good sequence without racing a real app.
  package typealias DataReader = @Sendable (URL) throws -> Data

  /// Two agreeing reads per acquisition, and at most this many acquisitions.
  private static let acquisitionAttempts = 3

  private let readOverride: DataReader?

  /// Both levels are OPTIONAL because that is what Handy's own decoder does,
  /// not because it is the lenient choice.
  ///
  /// `AppSettings` carries a container-level `#[serde(default)]` and
  /// `custom_words` a field-level one, and its own test
  /// `empty_store_parses_with_defaults` asserts that `{}` parses. An explicit
  /// `null` reaches the same place by a different route: `Vec<String>` cannot
  /// deserialize from null, so the strict decode fails and Handy's
  /// `salvage_settings` drops the field and keeps the default empty vector.
  ///
  /// So a document missing `settings`, missing `custom_words`, or holding null
  /// is not damaged — Handy itself reads it as a user with no custom words, and
  /// refusing it would tell them their store is unreadable while Handy opens
  /// the same file and shows them an empty list.
  ///
  /// Verified in `cjpais/Handy` at commit `db003f38`, `src-tauri/src/settings.rs`
  /// lines 338-340, 398-399, 949, 1002 and test 1140.
  ///
  /// ACCEPTED LIMIT: a future Handy that RENAMES or MOVES `custom_words` is
  /// therefore indistinguishable from a user with no custom words, and we would
  /// say "no words were found". Unhandled on purpose — every available fix
  /// requires predicting a schema nobody has seen, and the alternative refuses
  /// today's legitimate partial stores to defend against a speculative one.
  private struct Store: Decodable {
    struct Settings: Decodable {
      let customWords: [String]?
      enum CodingKeys: String, CodingKey { case customWords = "custom_words" }
    }
    let settings: Settings?
  }

  package var candidatePaths: [URL] {
    [
      FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.pais.handy/settings_store.json")
    ]
  }

  package init(readData: DataReader? = nil) {
    self.readOverride = readData
  }

  package func loadWords(at url: URL) throws -> SmartImportReadResult {
    let store: Store = try acquireStableSnapshot(
      appName: displayName,
      attempts: Self.acquisitionAttempts,
      read: { try readData(at: url) },
      agrees: { $0 == $1 },
      accept: { try JSONDecoder().decode(Store.self, from: $0) })

    // Only these two keys are decoded, which is also why an unrelated poisoned
    // field cannot block the read. Handy salvages such a document field by
    // field and keeps valid vocabulary out of it; decoding its WHOLE settings
    // object would refuse a file Handy itself reads happily.
    return SmartImportReadResult(
      words: (store.settings?.customWords ?? []).map { SmartImportWord(canonical: $0) })
  }

  private func readData(at url: URL) throws -> Data {
    if let readOverride { return try readOverride(url) }
    return try boundedData(at: url, appName: displayName)
  }
}

package struct SmartImportRegistry: Sendable {
  package let adapters: [any SmartImportAdapter]

  package static let v1 = SmartImportRegistry(
    adapters: [
      WisprFlowAdapter(), FluidVoiceAdapter(), SuperwhisperAdapter(),
      VoxAdapter(), TypeWhisperAdapter(), SpokenlyAdapter(), JunoAdapter(),
      HandyAdapter(),
    ])

  /// The display names, in registry order, for whoever writes the picker copy.
  ///
  /// The registry owns the NAMES; AppKit owns the SENTENCE. Keeping the
  /// formatter out of here stops user-facing English being pushed down a layer
  /// for test convenience, and the AppKit test target can reach it where it is.
  package var displayNames: [String] { adapters.map(\.displayName) }

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

    let readResult = try adapter.loadWords(at: path)
    let words = readResult.words
    try Task.checkCancellation()

    // Check the SCANNED row count, before deduplication (code review r10) and
    // before the adapter's own exclusions are subtracted.
    //
    // The adapters read one past the ceiling so that "too many" is knowable.
    // But dedup shrinks the list, so a source whose first 25,001 rows contain
    // duplicates would fall back under the limit and report a successful
    // import that had silently dropped everything beyond it. Every ceiling
    // needs a signal for having been reached; counting after the shrink loses
    // that signal — the same mistake the pasted-text parser made.
    //
    // Counting SCANNED rather than SURVIVING rows is new in #1773 and closes
    // the same loophole one layer out: an adapter that filtered 25,001 rows
    // down to one would otherwise look like a one-row source.
    let scannedCount = words.count + readResult.excludedCount
    guard scannedCount <= CustomWordsImportLimits.maximumCandidates else {
      // Deliberately NOT `ImportFileError.tooManyWords`, whose copy says "That
      // file" and "split it into smaller files" — a competitor's database is
      // neither a file the user chose nor splittable, and its deleted rows and
      // snippets are not "words".
      throw SmartImportError.tooManySourceEntries(
        appName: adapter.displayName, limit: CustomWordsImportLimits.maximumCandidates)
    }

    // Trim aliases up front so both the ceiling below and candidate
    // construction judge the same values that would actually get stored —
    // matching CustomWordsImportCandidate.storedValues's own rule (judge the
    // trimmed value, since that is what gets saved). Counting raw,
    // pre-trim aliases let a FluidVoice term padded with blank/whitespace-only
    // alias slots trip this ceiling on values that were always going to be
    // dropped and never stored (GitHub cloud review, PR #1748).
    let trimmedAliasesByIndex = words.map { word in
      word.aliases
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    }

    // A second, new ceiling: total stored surface (canonical + every alias),
    // not just row count. FluidVoice's real schema can attach an unbounded
    // alias array to one term, which the row-count check above cannot see.
    // Same all-or-nothing shape as the sibling ceiling above, reusing the
    // error family the Upload path already established for this concern.
    let storedValueCount = trimmedAliasesByIndex.reduce(into: 0) { count, aliases in
      count += 1 + aliases.count
    }
    guard storedValueCount <= CustomWordsImportLimits.maximumExportedStoredValues else {
      throw ImportFileError.tooManyStoredValues(
        found: storedValueCount, limit: CustomWordsImportLimits.maximumExportedStoredValues)
    }

    // Trim and drop blanks only; no merge here. Two rows resolving to the
    // same word are left for `CustomWordsImportCompareEngine.coalesceDuplicates`
    // downstream — the existing, already-tested owner of "should these merge"
    // (§3c) — rather than re-deciding it locally with a different key.
    var canonicals: [CustomWordsImportCandidate] = []
    // Blank canonicals dropped HERE are exclusions too. Leaving them out of
    // the count would let a source that produced only blanks still report
    // "no words were found", which is the untruth this count exists to stop.
    var excludedCount = readResult.excludedCount
    for (word, aliases) in zip(words, trimmedAliasesByIndex) {
      let trimmed = word.canonical.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !CustomWordsImportCompareEngine.normalize(trimmed).isEmpty else {
        excludedCount += 1
        continue
      }
      canonicals.append(
        CustomWordsImportCandidate(
          canonical: trimmed,
          aliases: aliases.isEmpty ? .unspecified : .supplied(aliases),
          caseSensitive: word.caseSensitive))
    }

    // One notice, only when the source had rows and none of them survived.
    // Counts only, never content.
    let notices: [CustomWordsImportNotice] =
      canonicals.isEmpty && excludedCount > 0
      ? [.incompatibleSourceEntriesExcluded(count: excludedCount)]
      : []

    return CustomWordsImportBatch(
      sourceID: adapter.identifier, sourceDisplayName: adapter.displayName,
      candidates: canonicals, notices: notices)
  }
}
