import EnviousWisprCore
import Foundation

/// Errors from decoding an EnviousWispr custom-words backup (#1680, PR-E1).
package enum CustomWordsTransferError: LocalizedError, Sendable, Equatable {
  case notAnEnviousWisprBackup
  case unsupportedVersion(Int)
  case malformed

  package var errorDescription: String? {
    switch self {
    case .notAnEnviousWisprBackup:
      return "That file didn't come from EnviousWispr."
    case .unsupportedVersion(let version):
      return
        "That file was exported by a newer version of EnviousWispr (format \(version)). "
        + "Update the app, then try again."
    case .malformed:
      return "That file is damaged and can't be read."
    }
  }
}

/// One exported word. Deliberately narrower than `CustomWord`: usage history
/// (`frequencyUsed` / `lastUsed`) never leaves this Mac, and `source` is a
/// runtime tag with no meaning on another machine.
package struct PortableCustomWord: Codable, Sendable, Equatable {
  package let id: UUID
  package let canonical: String
  package let aliases: [String]
  package let category: WordCategory
  package let priority: Int
  package let forceReplace: Bool
  package let caseSensitive: Bool
  package let minSimilarityOverride: Double?

  package init(_ word: CustomWord) {
    self.id = word.id
    self.canonical = word.canonical
    self.aliases = word.aliases
    self.category = word.category
    self.priority = word.priority
    self.forceReplace = word.forceReplace
    self.caseSensitive = word.caseSensitive
    self.minSimilarityOverride = word.minSimilarityOverride
  }
}

/// The portable backup format: a versioned envelope around the user's own words.
///
/// Scope is "your words", never "everything" — see the export path for why
/// built-ins are excluded and why deleted-built-in tombstones are a documented
/// non-goal rather than an oversight.
package struct CustomWordsTransferDocument: Codable, Sendable, Equatable {
  package static let formatIdentifier = "com.enviouswispr.custom-words"
  package static let currentVersion = 1

  package let format: String
  package let version: Int
  package let words: [PortableCustomWord]

  /// Export path.
  package init(words: [CustomWord]) {
    self.format = Self.formatIdentifier
    self.version = Self.currentVersion
    self.words = words.map(PortableCustomWord.init)
  }

  /// Just the envelope. Decoded first and alone so the format and version can
  /// be judged before any version-specific payload is parsed.
  private struct Header: Decodable {
    let format: String
    let version: Int
  }

  /// Decode path. Rejects anything that isn't this format, and refuses a
  /// version it cannot interpret rather than guessing at fields it doesn't know.
  package init(data: Data) throws {
    // Header FIRST (code review r3). A future format could rename a word field
    // or add an enum case; decoding the whole document up front would throw on
    // that payload before the version guard ran, and the user would be told
    // their backup is damaged when the truth is "made by a newer version —
    // update the app." Judge the envelope, then read the contents.
    let header: Header
    do {
      header = try JSONDecoder().decode(Header.self, from: data)
    } catch {
      // A perfectly valid JSON file that simply isn't ours reads the same as
      // damaged bytes at this layer; separate them so the message is true.
      //
      // "Valid JSON" includes a top-level array, string, or number — a config
      // file, an API dump, a word list someone saved as JSON. Those are
      // healthy documents that just aren't ours, and calling them damaged
      // sends the user hunting for corruption that isn't there (review r2).
      if let json = try? JSONSerialization.jsonObject(
        with: data, options: [.fragmentsAllowed])
      {
        let claimsOurFormat =
          (json as? [String: Any])?["format"] as? String == Self.formatIdentifier
        // Only a document claiming to BE ours can be damaged goods; anything
        // else is simply a different file.
        throw claimsOurFormat
          ? CustomWordsTransferError.malformed
          : CustomWordsTransferError.notAnEnviousWisprBackup
      }
      throw CustomWordsTransferError.malformed
    }
    guard header.format == Self.formatIdentifier else {
      throw CustomWordsTransferError.notAnEnviousWisprBackup
    }
    // A RANGE, not an upper bound — but the two ends mean different things and
    // must not share a message (review r4). Below 1 is a schema that never
    // existed, so the file is malformed or tampered; telling that user to
    // "update the app" is advice that cannot help them. Above current is a
    // genuine future format, where updating is exactly the fix.
    guard header.version >= 1 else {
      throw CustomWordsTransferError.malformed
    }
    guard header.version <= Self.currentVersion else {
      throw CustomWordsTransferError.unsupportedVersion(header.version)
    }

    let decoded: CustomWordsTransferDocument
    do {
      decoded = try JSONDecoder().decode(CustomWordsTransferDocument.self, from: data)
    } catch {
      // The envelope is ours and its version is supported, so a payload that
      // still won't parse is genuinely damaged.
      throw CustomWordsTransferError.malformed
    }
    self = decoded
  }

  package func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(self)
  }

  /// Hand the decoded words to the shared import pipeline.
  ///
  /// Never returns `[CustomWord]`: an exported `id` is a persistence UUID from
  /// whichever Mac wrote the file, and must not become a local persisted UUID.
  ///
  /// The exported id is **not reused as review identity either** (code review).
  /// Restoring a backup onto the Mac that wrote it makes every candidate id
  /// equal to the live word's id, and the collision detector — which seeds
  /// ownership from the existing library first — then reports each word's own
  /// aliases as colliding with itself. Review would warn that spellings "may
  /// not be added" when replacement keeps them. A fresh transient id per
  /// candidate keeps review rows distinct from library entries, which is the
  /// only thing this id is for.
  ///
  /// Every authority field is `.supplied`, including the two authoritative
  /// clears no other source can express: `.supplied([])` means "this word
  /// genuinely has no alternate spellings" and `.supplied(nil)` means "this
  /// word genuinely uses the global strictness". A backup is a full round-trip
  /// of a real word, so silence here would be a lie, not an absence of opinion.
  /// Throws on cancellation, because this is the expensive half of reading a
  /// large export and the sheet can be dismissed mid-flight. Without a check
  /// here the work carried on burning CPU and memory after the UI was gone
  /// (Codex review, #1683).
  package func candidatesForImport() throws -> [CustomWordsImportCandidate] {
    try words.enumerated().map { index, word in
      // Cancellation is cheap to observe but not free, so check per batch
      // rather than per word.
      if index.isMultiple(of: 1_000) { try Task.checkCancellation() }
      return
      CustomWordsImportCandidate(
        id: UUID(),
        canonical: word.canonical,
        aliases: .supplied(word.aliases),
        suggestedAliases: [],
        category: .supplied(word.category),
        priority: .supplied(word.priority),
        forceReplace: .supplied(word.forceReplace),
        caseSensitive: .supplied(word.caseSensitive),
        minSimilarityOverride: .supplied(word.minSimilarityOverride)
      )
    }
  }
}
