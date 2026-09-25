import EnviousWisprCore
import Foundation

/// Errors from decoding an `EnviousWispr Snippets.json` (#2997). Mirrors
/// `CustomWordsTransferError`, sentence for sentence, so the two files a user can pick fail
/// in the same voice.
package enum SnippetsTransferError: LocalizedError, Sendable, Equatable {
  case notAnEnviousWisprSnippetsFile
  case unsupportedVersion(Int)
  case malformed

  package var errorDescription: String? {
    switch self {
    case .notAnEnviousWisprSnippetsFile:
      return String(
        localized:
          "That file isn't an EnviousWispr snippets file.",
        comment:
          "Snippets, import: error when the file is not a snippets export.")
    case .unsupportedVersion(let version):
      return String(
        localized:
          "That file was exported by a newer version of EnviousWispr (format \(String(version))). Update the app, then try again.",
        comment:
          "Snippets, import: error. %@ is the file's format version number.")
    case .malformed:
      return String(
        localized:
          "That file is damaged and can't be read.",
        comment:
          "Snippets, import: error when the file is damaged.")
    }
  }
}

/// The file Export writes and Import reads (#628 export, #2997 import).
///
/// Moved here from the export action so the same type is both written and decoded; two
/// definitions of one file format is how a field goes missing on one side. Deliberately
/// the same field names the store persists (`SnippetsManager.StoredFile`), so a file a user
/// keeps for a year still means what it says, and Import has nothing to translate. The
/// bytes an exported file carries are unchanged by the move: `DurableJSONFile.write`
/// encodes with `.prettyPrinted` and `.sortedKeys` from the field names alone.
///
/// There is no `format` marker, unlike the words file, because v1 shipped without one and
/// changing the written bytes would make every existing export "not ours". A document is
/// recognised as ours by its shape: a top-level object carrying a `snippets` key.
package struct SnippetsTransferDocument: Codable, Sendable, Equatable {
  package let version: Int
  /// Carried for the record and NEVER applied on import (founder 2026-09-16: the keyword is
  /// something the customer tweaks in Settings, not something we import).
  package let keyword: String
  package let snippets: [Snippet]

  /// Export path.
  package init(version: Int, keyword: String, snippets: [Snippet]) {
    self.version = version
    self.keyword = keyword
    self.snippets = snippets
  }

  /// Just the envelope, decoded first and alone so the version can be judged before any
  /// version-specific payload is parsed. A future format could add a field to `Snippet`;
  /// decoding everything up front would throw on that payload before the version guard ran,
  /// and the user would be told the file is damaged when the truth is "made by a newer
  /// version, update the app".
  private struct Header: Decodable {
    let version: Int
    let snippets: [AnyDecodable]
  }
  private struct AnyDecodable: Decodable {}

  /// Decode path. Refuses anything that is not this shape, and a version it cannot read.
  /// Whether the bytes parse as JSON at all. The paste sniff routes a brace-led paste here
  /// only when they do, so a list line that starts with a brace is never called a damaged
  /// export.
  package static func isJSON(_ data: Data) -> Bool {
    (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
  }

  /// The ONE ownership test: a top-level JSON object carrying a `snippets` key claims to be
  /// ours (a missing or broken `version` beside it is damage, not a different file).
  package static func looksLikeOurs(_ data: Data) -> Bool {
    guard let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    else { return false }
    return (json as? [String: Any])?["snippets"] != nil
  }

  package init(data: Data) throws {
    let header: Header
    do {
      header = try JSONDecoder().decode(Header.self, from: data)
    } catch {
      // Valid JSON that simply is not ours (an array, a config file, the words export)
      // reads the same as damaged bytes at this layer; keep the two messages true.
      if Self.isJSON(data) {
        throw Self.looksLikeOurs(data)
          ? SnippetsTransferError.malformed
          : SnippetsTransferError.notAnEnviousWisprSnippetsFile
      }
      throw SnippetsTransferError.malformed
    }
    // A RANGE, not an upper bound: below 1 is a schema that never existed, so the file is
    // malformed; above current is a genuine future format, where updating is the fix.
    guard header.version >= 1 else { throw SnippetsTransferError.malformed }
    guard header.version <= SnippetsManager.currentVersion else {
      throw SnippetsTransferError.unsupportedVersion(header.version)
    }
    do {
      self = try JSONDecoder().decode(SnippetsTransferDocument.self, from: data)
    } catch {
      throw SnippetsTransferError.malformed
    }
  }
}
