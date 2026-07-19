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
      return "That file isn't an EnviousWispr word backup."
    case .unsupportedVersion(let version):
      return
        "That backup was made by a newer version of EnviousWispr (format \(version)). "
        + "Update the app, then try again."
    case .malformed:
      return "That backup file is damaged and can't be read."
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

  /// Decode path. Rejects anything that isn't this format, and refuses a
  /// version from the future rather than guessing at fields it doesn't know.
  package init(data: Data) throws {
    let decoded: CustomWordsTransferDocument
    do {
      decoded = try JSONDecoder().decode(CustomWordsTransferDocument.self, from: data)
    } catch {
      // A valid JSON object that simply isn't ours decodes as a key mismatch,
      // same as damaged bytes; distinguish them so the user gets the right
      // sentence rather than "damaged" for a perfectly fine unrelated file.
      if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        object["format"] as? String != Self.formatIdentifier
      {
        throw CustomWordsTransferError.notAnEnviousWisprBackup
      }
      throw CustomWordsTransferError.malformed
    }
    guard decoded.format == Self.formatIdentifier else {
      throw CustomWordsTransferError.notAnEnviousWisprBackup
    }
    // A RANGE, not an upper bound. Version 1 is the first format and nothing
    // earlier ever existed, so `0` or a negative version is a malformed or
    // tampered file claiming a schema that was never defined — not something
    // to import on the strength of the current fields happening to parse.
    guard (1...Self.currentVersion).contains(decoded.version) else {
      throw CustomWordsTransferError.unsupportedVersion(decoded.version)
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
  package func candidatesForImport() -> [CustomWordsImportCandidate] {
    words.map { word in
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
