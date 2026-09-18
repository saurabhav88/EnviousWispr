// AliasRunner `judge` subcommand — issue #996 (learn custom words from edits).
//
// Runs one correction-judge candidate over the labelled edit corpus and emits
// one JSONL record per row for `scripts/eval/edit_judge_gate.py` to score.
// Chunk 1 ships the CONTRACT and a fixture executor only: every real judge
// (J1 rules, J2 AFM on macOS 26, J3 AFM on macOS 27, J4 Ollama, J5 the user's
// cloud provider) reports `unimplemented` explicitly. Nothing here ever falls
// back to another judge: an unavailable judge is a row outcome, never a
// silently substituted answer, because the scorer counts a bypass against
// recall and a silent substitution would score the wrong judge.
//
// Library target so the contract is testable; `main.swift` only dispatches.

import Foundation

// MARK: - Corpus row

/// One labelled edit. Exactly one changed run per row so a row is one
/// candidate and the scorer's denominators are rows, not runs.
package struct EditCorpusRow: Decodable, Sendable, Equatable {
  package let id: String
  package let stratum: String
  package let language: String
  /// The full sentence as pasted (the recogniser's output).
  package let pasted: String
  /// The full sentence after the user's edit.
  package let edited: String
  /// The changed run inside `pasted` (what the recogniser wrote).
  package let original: String
  /// The changed run inside `edited` (what the user typed).
  package let replacement: String
  /// Human label: a name, term or spelling fix (true) versus a rewording,
  /// grammar, formatting or instruction-like edit (false).
  package let correction: Bool
  /// Human label: replacing `original` with `replacement` in future dictations
  /// would almost always be right.
  package let safeAlias: Bool
  package let labelSource: String

  enum CodingKeys: String, CodingKey {
    case id, stratum, language, pasted, edited, original, replacement, correction
    case safeAlias = "safe_alias"
    case labelSource = "label_source"
  }
}

// MARK: - Judge candidates

/// The closed set of judges the eval can name. Matches plan §2.2 J1-J5 plus
/// the fixture executor the harness tests use. A judge that is not built yet
/// is still a MEMBER so that asking for it produces an explicit
/// `unimplemented` outcome instead of an unknown-argument error that could be
/// mistaken for a typo.
package enum JudgeCandidate: String, CaseIterable, Sendable {
  case fixture
  case j1Rules = "j1-rules"
  case j2AFM26 = "j2-afm-macos26"
  case j3AFM27 = "j3-afm-macos27"
  case j4Ollama = "j4-ollama"
  case j5CloudProvider = "j5-cloud-provider"

  package static var usageList: String {
    allCases.map(\.rawValue).joined(separator: "|")
  }
}

// MARK: - Result record

/// Outcome vocabulary shared with the production seam planned in Chunk 2
/// (`CorrectionJudgeOutcome`): a verdict, or one typed bypass. The scorer
/// treats every non-verdict as a bypass that COUNTS against recall.
package enum JudgeOutcome: String, Codable, Sendable {
  case verdict
  case unavailable
  case notGranted = "not_granted"
  case deadline
  case cancelled
  case malformed
  case unimplemented
}

package struct JudgeDecision: Codable, Sendable, Equatable {
  package let vocabularyCorrection: Bool
  package let safeAlias: Bool

  enum CodingKeys: String, CodingKey {
    case vocabularyCorrection = "vocabulary_correction"
    case safeAlias = "safe_alias"
  }

  package init(vocabularyCorrection: Bool, safeAlias: Bool) {
    self.vocabularyCorrection = vocabularyCorrection
    self.safeAlias = safeAlias
  }
}

package struct JudgeRecord: Codable, Sendable, Equatable {
  package let id: String
  package let judge: String
  package let outcome: JudgeOutcome
  /// Present only when `outcome == .verdict`.
  package let decision: JudgeDecision?
  package let latencyMs: Double
  /// Human-readable reason for a bypass; never the row's text.
  package let note: String?

  enum CodingKeys: String, CodingKey {
    case id, judge, outcome, decision, note
    case latencyMs = "latency_ms"
  }
}

// MARK: - Fixture executor

/// A fixture answers rows from a JSON file `{ "<row id>": <entry> }` where
/// `<entry>` is either `{"vocabulary_correction": Bool, "safe_alias": Bool}`
/// or `{"outcome": "<bypass name>"}`. A row the fixture does not name is
/// `malformed` (the fixture is incomplete), never a default answer, so an
/// incomplete fixture cannot read as a judge that declined.
package struct JudgeFixture: Sendable {
  package enum Entry: Sendable, Equatable {
    case decision(JudgeDecision)
    case bypass(JudgeOutcome)
  }

  package let entries: [String: Entry]

  package init(entries: [String: Entry]) { self.entries = entries }

  package static func load(from data: Data) throws -> JudgeFixture {
    struct RawEntry: Decodable {
      let vocabulary_correction: Bool?
      let safe_alias: Bool?
      let outcome: String?
    }
    let raw = try JSONDecoder().decode([String: RawEntry].self, from: data)
    var entries: [String: Entry] = [:]
    for (id, e) in raw {
      if let name = e.outcome {
        guard let outcome = JudgeOutcome(rawValue: name), outcome != .verdict else {
          throw FixtureError.badEntry(id: id, reason: "outcome must be a bypass name, got \(name)")
        }
        entries[id] = .bypass(outcome)
      } else if let v = e.vocabulary_correction, let s = e.safe_alias {
        entries[id] = .decision(JudgeDecision(vocabularyCorrection: v, safeAlias: s))
      } else {
        throw FixtureError.badEntry(
          id: id, reason: "entry needs both booleans or an outcome")
      }
    }
    return JudgeFixture(entries: entries)
  }

  package enum FixtureError: Error, Equatable {
    case badEntry(id: String, reason: String)
  }
}

// MARK: - Runner

package enum JudgeRunner {
  /// Judge every row with the fixture. Pure: the caller supplies the clock so
  /// the latency column is testable without sleeping.
  package static func run(
    rows: [EditCorpusRow], fixture: JudgeFixture, judgeName: String = JudgeCandidate.fixture.rawValue,
    clock: () -> Double = { Date().timeIntervalSince1970 * 1000 }
  ) -> [JudgeRecord] {
    rows.map { row in
      let start = clock()
      let record: JudgeRecord
      switch fixture.entries[row.id] {
      case .decision(let d)?:
        record = JudgeRecord(
          id: row.id, judge: judgeName, outcome: .verdict, decision: d,
          latencyMs: clock() - start, note: nil)
      case .bypass(let outcome)?:
        record = JudgeRecord(
          id: row.id, judge: judgeName, outcome: outcome, decision: nil,
          latencyMs: clock() - start, note: "fixture bypass")
      case nil:
        record = JudgeRecord(
          id: row.id, judge: judgeName, outcome: .malformed, decision: nil,
          latencyMs: clock() - start, note: "fixture has no entry for this row")
      }
      return record
    }
  }

  /// Records for a judge that is not built yet: one explicit `unimplemented`
  /// row per corpus row, so the scorer sees the full denominator and a 0%
  /// recall, never an empty results file that could pass a "no failures" read.
  package static func unimplemented(rows: [EditCorpusRow], judge: JudgeCandidate) -> [JudgeRecord] {
    rows.map { row in
      JudgeRecord(
        id: row.id, judge: judge.rawValue, outcome: .unimplemented, decision: nil,
        latencyMs: 0, note: "judge \(judge.rawValue) is not implemented in this build")
    }
  }
}

// MARK: - Corpus loading

package enum CorpusLoadError: Error, Equatable {
  case unreadable(path: String)
  case badLine(number: Int, reason: String)
  case duplicateID(String)
  case empty
}

package enum EditCorpus {
  package static func load(text: String) throws -> [EditCorpusRow] {
    let decoder = JSONDecoder()
    var rows: [EditCorpusRow] = []
    var seen: Set<String> = []
    for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty { continue }
      let row: EditCorpusRow
      do {
        row = try decoder.decode(EditCorpusRow.self, from: Data(trimmed.utf8))
      } catch {
        throw CorpusLoadError.badLine(number: index + 1, reason: String(describing: error))
      }
      guard seen.insert(row.id).inserted else { throw CorpusLoadError.duplicateID(row.id) }
      rows.append(row)
    }
    guard !rows.isEmpty else { throw CorpusLoadError.empty }
    return rows
  }

  package static func load(path: String) throws -> [EditCorpusRow] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
      throw CorpusLoadError.unreadable(path: path)
    }
    return try load(text: text)
  }
}

// MARK: - CLI

package struct JudgeArgs: Equatable, Sendable {
  package var corpusPath: String
  package var outPath: String?
  package var judge: JudgeCandidate
  package var fixturePath: String?

  package init(corpusPath: String, outPath: String?, judge: JudgeCandidate, fixturePath: String?) {
    self.corpusPath = corpusPath
    self.outPath = outPath
    self.judge = judge
    self.fixturePath = fixturePath
  }
}

package enum JudgeArgsError: Error, Equatable {
  case missingCorpus
  case missingJudge
  case unknownJudge(String)
  case unknownArgument(String)
  case missingValue(String)
  case fixtureRequiresFixturePath
  case fixturePathOnlyWithFixtureJudge
}

package enum JudgeCLI {
  package static let usage = """
    AliasRunner judge --corpus <path> --judge <\(JudgeCandidate.usageList)>
                      [--out <path>] [--fixture <path>]

    Emits one JSON object per corpus row (keys sorted). `--judge fixture`
    requires `--fixture <json>`. Every other judge is a named candidate; a
    candidate that this build does not implement writes `unimplemented` for
    every row and exits 3.
    """

  /// Parses the arguments AFTER the `judge` word.
  package static func parse(_ argv: [String]) throws -> JudgeArgs {
    var corpus: String?
    var out: String?
    var judge: JudgeCandidate?
    var fixture: String?
    var it = argv.makeIterator()
    while let arg = it.next() {
      switch arg {
      case "--corpus":
        guard let v = it.next() else { throw JudgeArgsError.missingValue(arg) }
        corpus = v
      case "--out":
        guard let v = it.next() else { throw JudgeArgsError.missingValue(arg) }
        out = v
      case "--judge":
        guard let v = it.next() else { throw JudgeArgsError.missingValue(arg) }
        guard let j = JudgeCandidate(rawValue: v) else { throw JudgeArgsError.unknownJudge(v) }
        judge = j
      case "--fixture":
        guard let v = it.next() else { throw JudgeArgsError.missingValue(arg) }
        fixture = v
      default:
        throw JudgeArgsError.unknownArgument(arg)
      }
    }
    guard let corpus else { throw JudgeArgsError.missingCorpus }
    guard let judge else { throw JudgeArgsError.missingJudge }
    if judge == .fixture, fixture == nil { throw JudgeArgsError.fixtureRequiresFixturePath }
    if judge != .fixture, fixture != nil { throw JudgeArgsError.fixturePathOnlyWithFixtureJudge }
    return JudgeArgs(corpusPath: corpus, outPath: out, judge: judge, fixturePath: fixture)
  }

  /// Exit codes: 0 records written and every row got a verdict or a fixture
  /// bypass; 2 usage/infra (matches the alias command); 3 the named judge is
  /// unimplemented in this build (records still written so the scorer sees
  /// the denominator).
  package static func execute(args: JudgeArgs) -> (records: [JudgeRecord], exitCode: Int32) {
    let rows: [EditCorpusRow]
    do {
      rows = try EditCorpus.load(path: args.corpusPath)
    } catch {
      return ([], 2)
    }
    switch args.judge {
    case .fixture:
      guard let fixturePath = args.fixturePath,
        let data = FileManager.default.contents(atPath: fixturePath),
        let fixture = try? JudgeFixture.load(from: data)
      else { return ([], 2) }
      return (JudgeRunner.run(rows: rows, fixture: fixture), 0)
    case .j1Rules, .j2AFM26, .j3AFM27, .j4Ollama, .j5CloudProvider:
      return (JudgeRunner.unimplemented(rows: rows, judge: args.judge), 3)
    }
  }

  package static func encode(_ records: [JudgeRecord]) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var lines: [String] = []
    for r in records {
      let data = try encoder.encode(r)
      lines.append(String(decoding: data, as: UTF8.self))
    }
    return lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
  }
}
