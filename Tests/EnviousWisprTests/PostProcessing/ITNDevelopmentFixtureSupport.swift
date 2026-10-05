import Foundation
import Testing

// MARK: - The frozen German development and control rows (#1677, PR 2 chunk 3)
//
// ONE loader for the two corpus files the number and protection primitives may read:
// `de-development.jsonl` (conversion rows) and `de-controls.jsonl` (lexical and already-formatted
// controls). Only panel-reviewed rows count; pending rows stay in the files and are excluded.
//
// The third corpus file, the fresh-sentence acceptance set, is deliberately NOT readable from this
// loader or from any test that uses it: it is opened for the first time by the acceptance chunk.
// `ITNDevelopmentFixtureSupport.swift` and its callers hold no path to it, and a drift guard in
// `LanguageNumberParserTests` fails if one appears.
//
// Rows are read field by field from the files. Nothing here keeps a second copy of a corpus
// sentence, a number lexicon or a refusal list.

enum ITNDevelopmentFixtures {

  struct TargetSpan: Decodable, Sendable {
    let spokenSpan: String
    let writtenForms: [String]
  }

  struct Row: Decodable, Sendable {
    let id: String
    let category: String
    let split: String
    let spokenInput: String
    let expectedAction: String
    let refusalReason: String?
    let targetSpans: [TargetSpan]
    let acceptedWrittenVariants: [String]
    let panelStatus: String
  }

  struct Loaded: Sendable {
    /// Panel-reviewed rows only.
    let rows: [Row]
    /// Every row in the file, reviewed or not.
    let totalInFile: Int

    var pendingExcluded: Int { totalInFile - rows.count }
  }

  static func development() throws -> Loaded { try load("de-development.jsonl") }
  static func controls() throws -> Loaded { try load("de-controls.jsonl") }

  private static func load(_ fileName: String) throws -> Loaded {
    let url = RepoRoot.url.appending(path: "scripts/itn/corpus/\(fileName)")
    let text = try String(contentsOf: url, encoding: .utf8)
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    var all: [Row] = []
    for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
    {
      if line.isEmpty { continue }
      do {
        all.append(try decoder.decode(Row.self, from: Data(line.utf8)))
      } catch {
        Issue.record("\(fileName):\(index + 1) is not a corpus row: \(error)")
      }
    }
    return Loaded(rows: all.filter { $0.panelStatus == "panel-reviewed" }, totalInFile: all.count)
  }
}

/// UTF-16 location helpers the tests use to find where a corpus span sits in its sentence, with
/// `NSString` as an instrument independent of the code under test.
enum ITNFixtureRanges {
  /// The UTF-16 range of the first occurrence of `needle` in `haystack`, optionally restricted to
  /// a sub-range, searching backwards when asked.
  static func range(
    of needle: String, in haystack: String, within bounds: Range<Int>? = nil,
    backwards: Bool = false
  ) -> Range<Int>? {
    let ns = haystack as NSString
    let search =
      bounds.map { NSRange(location: $0.lowerBound, length: $0.count) }
      ?? NSRange(location: 0, length: ns.length)
    let found = ns.range(
      of: needle, options: backwards ? [.backwards, .literal] : [.literal], range: search)
    guard found.location != NSNotFound else { return nil }
    return found.location..<(found.location + found.length)
  }
}
