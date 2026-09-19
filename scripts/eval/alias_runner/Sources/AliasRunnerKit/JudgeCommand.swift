// AliasRunner `judge` subcommand — issue #996 (learn custom words from edits).
//
// Runs one correction-judge candidate over the labelled edit corpus and emits
// one JSONL record per row for `scripts/eval/edit_judge_gate.py` to score.
// Chunks 1 and 2a ship the CONTRACT and a fixture executor only: every real
// judge (rules, AFM on macOS 26 and 27, the three cross-encoder classifiers,
// the deferred Qwen arm) reports `unimplemented` explicitly. Nothing here ever
// falls back to another judge: an unavailable judge is a row outcome, never a
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

/// The closed set of judges the eval can name: plan §2.2 (revised 2026-09-18
/// after the council round and Codex build round 2) plus the fixture executor
/// the harness tests use. The user's Ollama polish model and cloud polish
/// provider were removed as candidates (founder: the judge is a very specific
/// job). A judge that is not built yet is still a MEMBER so that asking for it
/// produces an explicit `unimplemented` outcome instead of an unknown-argument
/// error that could be mistaken for a typo.
package enum JudgeCandidate: String, CaseIterable, Sendable {
  case fixture
  /// Deterministic rules only (macOS 14+).
  case rules
  /// Apple FoundationModels on real macOS 26 hardware (comparison arm).
  case afmMacOS26 = "afm-macos26"
  /// Apple FoundationModels on macOS 27 (comparison arm).
  case afmMacOS27 = "afm-macos27"
  /// Cross-encoder pair classifiers fine-tuned by us, run through Core ML.
  case xencMMBERTSmall = "xenc-mmbert-small"
  case xencMDeBERTaV3Base = "xenc-mdeberta-v3-base"
  case xencXLMRBase = "xenc-xlmr-base"
  /// Qwen3-0.6B Q4 through the bundled llama-server. DEFERRED: built only if
  /// every cross-encoder fails feasibility or the §3a bar.
  case qwen3_0_6B = "qwen3-0.6b-q4"

  package enum Status: String, Sendable {
    /// Answers rows from a JSON file; harness tests only.
    case fixture
    /// A real candidate this build does not implement yet.
    case unimplemented
    /// A comparison arm the plan defers; not built unless the others fail.
    case deferred
  }

  package var status: Status {
    switch self {
    case .fixture: return .fixture
    case .rules, .afmMacOS26, .afmMacOS27, .xencMMBERTSmall, .xencMDeBERTaV3Base, .xencXLMRBase:
      // `.rules` and the two AFM arms are registered by the runner binary
      // (`DoorJudgeArm.arms()`); this status describes the KIT alone, which
      // implements nothing itself. A candidate with no registered arm is
      // reported `unimplemented` by `execute`.
      return .unimplemented
    case .qwen3_0_6B: return .deferred
    }
  }

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
  /// What actually ran: immutable digests (checkpoint, tokenizer, decision
  /// configuration) or, for an AFM arm, the OS/model environment and prompt
  /// digest, DERIVED by the judge from what it loaded. The scorer requires
  /// every frozen-report record to carry the training manifest's identity,
  /// so results from one checkpoint cannot be scored under another's clean
  /// training declaration. `nil` means unexecuted (fixture, unimplemented,
  /// deferred): such records are never acceptance evidence.
  package let executionIdentity: [String: String]?

  enum CodingKeys: String, CodingKey {
    case id, judge, outcome, decision, note
    case latencyMs = "latency_ms"
    case executionIdentity = "execution_identity"
  }

  package init(
    id: String, judge: String, outcome: JudgeOutcome, decision: JudgeDecision?, latencyMs: Double,
    note: String?, executionIdentity: [String: String]? = nil
  ) {
    self.id = id
    self.judge = judge
    self.outcome = outcome
    self.decision = decision
    self.latencyMs = latencyMs
    self.note = note
    self.executionIdentity = executionIdentity
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
  /// A deferred arm says so in its note, so a reader can tell "not built yet"
  /// from "not built on purpose".
  package static func unimplemented(rows: [EditCorpusRow], judge: JudgeCandidate) -> [JudgeRecord] {
    let note: String
    switch judge.status {
    case .deferred:
      note = "judge \(judge.rawValue) is deferred by plan §2.2; not built in this build"
    case .unimplemented, .fixture:
      note = "judge \(judge.rawValue) is not implemented in this build"
    }
    return rows.map { row in
      JudgeRecord(
        id: row.id, judge: judge.rawValue, outcome: .unimplemented, decision: nil,
        latencyMs: 0, note: note)
    }
  }
}

// MARK: - Judge arms

/// A real judge the executable wires in: it answers one corpus row (one
/// candidate, the pasted sentence as context) with a record carrying the
/// judge's own execution identity. The kit stays free of root products; the
/// executable supplies the arms it can build (AFM through the benchmark
/// door in chunk 2b, Core ML in 2d).
package protocol JudgeArm: Sendable {
  func judge(row: EditCorpusRow) async -> JudgeRecord
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
  /// `arms` are the judges this build can actually run, keyed by candidate;
  /// a candidate with no arm is reported `unimplemented` (exit 3). Rows are
  /// judged sequentially so one arm's permit and deadline are measured per
  /// row, never overlapped.
  package static func execute(
    args: JudgeArgs, arms: [JudgeCandidate: any JudgeArm] = [:]
  ) async -> (records: [JudgeRecord], exitCode: Int32) {
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
    case .rules, .afmMacOS26, .afmMacOS27, .xencMMBERTSmall, .xencMDeBERTaV3Base, .xencXLMRBase,
      .qwen3_0_6B:
      guard let arm = arms[args.judge] else {
        return (JudgeRunner.unimplemented(rows: rows, judge: args.judge), 3)
      }
      var records: [JudgeRecord] = []
      records.reserveCapacity(rows.count)
      for row in rows {
        records.append(await arm.judge(row: row))
      }
      return (records, 0)
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
