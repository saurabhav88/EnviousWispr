import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// The language-gate benchmark (#2614): real engine transcripts of foreign-language speech
/// whose words collide with the English cleanup rules, run through the app's OWN deterministic
/// chain, with an oracle written before any run.
///
/// The fixture is produced by `scripts/eval/language_gate_corpus.py`: every sentence was spoken
/// by an Azure neural voice in its own language and transcribed by BOTH shipped engines, so the
/// text entering the chain is the text a user's speech actually yields, not a hand-typed
/// approximation. Each row names the words that are lexical in its language and must survive
/// cleanup (`must_keep`), the written form an English control must reach (`must_convert`), and
/// the fillers an English control must lose (`must_drop`).
///
/// A row is STAGED only when the engine actually emitted its oracle word; a misrecognition is
/// reported as unreachable rather than as a pass. The verdict is therefore about the CHAIN, never
/// about the recogniser.
///
/// When this fails, the user sees a real word of their own language rewritten or deleted:
/// Dutch "ten minste" pasted as "10 minste", German "er" (he) stripped as a hesitation.
@MainActor
@Suite("LanguageGateBenchmark", .tags(.productOutcome))
struct LanguageGateBenchmarkTests {

  // MARK: - Fixture

  struct Row: Decodable {
    let id: String
    let locale: String
    let lang: String
    let bucket: String
    let text: String
    let engine: String
    let raw: String
    let engine_language: String?
    let must_keep: [String]
    let must_convert: [String]
    let must_drop: [String]
  }

  /// `<repo>/Tests/EnviousWisprTests/Resources/LanguageGate/transcripts.jsonl`, located from
  /// `#filePath` the same way `InverseTextNormalizerParityTests` finds its fixture.
  static let fixtureURL: URL = URL(filePath: #filePath)
    .deletingLastPathComponent()  // Pipeline
    .deletingLastPathComponent()  // EnviousWisprTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // repo root
    .appending(path: "Tests/EnviousWisprTests/Resources/LanguageGate/transcripts.jsonl")

  static func loadRows() throws -> [Row] {
    let text = try String(contentsOf: fixtureURL, encoding: .utf8)
    let decoder = JSONDecoder()
    return try text.split(separator: "\n").compactMap { line in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      // The first line is a `_meta` header carrying provenance, not a row.
      guard !trimmed.isEmpty, !trimmed.hasPrefix("{\"_meta\"") else { return nil }
      return try decoder.decode(Row.self, from: Data(trimmed.utf8))
    }
  }

  // MARK: - The chain under test

  /// The shipped deterministic chain a DEFAULT user runs on the way to polish: every text-cleanup
  /// toggle ON, spoken punctuation OFF (#1794), no custom words, no snippets, no polish. Polish is
  /// deliberately absent: the benchmark measures the deterministic layer, and a model's output is
  /// graded by an LLM judge, never by string checks (code-validation.md
  /// RULE: polish-quality-is-graded-by-llm-judgement-only).
  static func deterministicChain(engine: String) -> [any TextProcessingStep] {
    let wordCorrection = WordCorrectionStep()
    wordCorrection.wordCorrectionEnabled = true
    let filler = FillerRemovalStep()
    filler.fillerRemovalEnabled = true
    let emoji = EmojiFormatterStep()
    emoji.emojiFormatterEnabled = true
    let itn = InverseTextNormalizationStep()
    itn.spokenPunctuationEnabled = false
    // The per-session capability hint `KernelFinalizationWiring` wires from the adapter:
    // WhisperKit declares language detection, Parakeet does not.
    itn.backendSupportsLID = engine == "whisperkit"
    return [SnippetExpansionStep(), wordCorrection, filler, emoji, itn]
  }

  /// Runs one transcript through the chain exactly as the live path seeds it under Automatic:
  /// the locked language is nil, and nothing else about the language reaches the runner.
  static func clean(_ row: Row) async throws -> String {
    let executor = FakeTimeoutExecutor(throwBelowSeconds: 0.0)
    let runner = TextProcessingRunner(telemetry: .silent, timeoutExecutor: executor.run)
    let result = try await runner.run(
      rawText: row.raw,
      language: nil,
      targetAppName: nil,
      steps: deterministicChain(engine: row.engine))
    return result.context.text
  }

  // MARK: - Oracle

  /// Whole-word, case-SENSITIVE presence. The oracle word is compared in the surface form the
  /// engine emitted, so "8 am" rewritten to "8 AM" counts as damage: the user's lowercase German
  /// preposition became an English time suffix.
  static func words(_ text: String) -> [Substring] {
    text.split { !$0.isLetter && !$0.isNumber }
  }

  static func containsWord(_ text: String, _ word: String) -> Bool {
    words(text).contains { $0 == Substring(word) }
  }

  static func containsWordInsensitive(_ text: String, _ word: String) -> Bool {
    let lowered = word.lowercased()
    return words(text).contains { $0.lowercased() == lowered }
  }

  struct Outcome: Encodable {
    let id: String
    let engine: String
    let lang: String
    let bucket: String
    let raw: String
    let cleaned: String
    let staged: Bool
    let damaged: [String]
    let missingConversions: [String]
    let survivingFillers: [String]
    let changed: Bool
    /// False for observe-only rows (no `must_keep`), which can never be staged or damaged.
    let hasOracle: Bool
  }

  static func grade(_ row: Row, cleaned: String) -> Outcome {
    let staged = row.must_keep.allSatisfy { containsWord(row.raw, $0) }
    let damaged = staged ? row.must_keep.filter { !containsWord(cleaned, $0) } : []
    let missing = row.must_convert.filter { !cleaned.contains($0) }
    let surviving = row.must_drop.filter { containsWordInsensitive(cleaned, $0) }
    return Outcome(
      id: row.id, engine: row.engine, lang: row.lang, bucket: row.bucket,
      raw: row.raw, cleaned: cleaned, staged: staged, damaged: damaged,
      missingConversions: missing, survivingFillers: surviving, changed: cleaned != row.raw,
      hasOracle: !row.must_keep.isEmpty)
  }

  // MARK: - Report

  /// Every outcome, written where a plan or a PR can cite it. The path is printed so the run log
  /// carries it; the file itself is never read by the test.
  static func writeReport(_ outcomes: [Outcome]) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "language-gate-benchmark")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appending(path: "report-\(Int(Date().timeIntervalSince1970)).json")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(outcomes).write(to: url)
    return url
  }

  // MARK: - Tests

  @Test("fixture is present and both engines are represented")
  func fixtureShape() throws {
    let rows = try Self.loadRows()
    #expect(rows.count > 200, "fixture looks truncated: \(rows.count) rows")
    let engines = Set(rows.map(\.engine))
    #expect(engines == ["parakeet", "whisperkit"], "engines present: \(engines.sorted())")
    #expect(Set(rows.map(\.lang)).count >= 20, "languages: \(Set(rows.map(\.lang)).count)")
  }

  @Test("no foreign word that the engine emitted is rewritten or deleted by the English rules")
  func foreignWordsSurviveCleanup() async throws {
    let rows = try Self.loadRows()
    var outcomes: [Outcome] = []
    for row in rows {
      let cleaned = try await Self.clean(row)
      outcomes.append(Self.grade(row, cleaned: cleaned))
    }
    let report = try Self.writeReport(outcomes)

    let staged = outcomes.filter { $0.staged && $0.hasOracle && !$0.bucket.hasPrefix("english") }
    let damaged = staged.filter { !$0.damaged.isEmpty }
    let byEngine = Dictionary(grouping: damaged, by: \.engine).mapValues(\.count)
    print(
      "LanguageGateBenchmark: staged=\(staged.count) damaged=\(damaged.count) "
        + "byEngine=\(byEngine) report=\(report.path)")
    for o in damaged {
      print("  DAMAGED \(o.id) [\(o.engine)] lost \(o.damaged): \(o.raw) -> \(o.cleaned)")
    }

    #expect(staged.count >= 80, "too few staged collision rows to mean anything: \(staged.count)")
    let damagedIDs = damaged.map(\.id).joined(separator: ", ")
    #expect(
      damaged.isEmpty,
      "\(damaged.count) of \(staged.count) staged foreign rows lost a real word to the English rules: \(damagedIDs)"
    )
  }

  @Test("English controls still convert numbers and still drop fillers, on both engines")
  func englishControlsStillConvert() async throws {
    let rows = try Self.loadRows().filter { $0.bucket.hasPrefix("english") }
    var failures: [String] = []
    for row in rows {
      let cleaned = try await Self.clean(row)
      let o = Self.grade(row, cleaned: cleaned)
      if !o.missingConversions.isEmpty {
        failures.append("\(o.id) [\(o.engine)] missing \(o.missingConversions): \(o.cleaned)")
      }
      if !o.survivingFillers.isEmpty {
        failures.append("\(o.id) [\(o.engine)] kept filler \(o.survivingFillers): \(o.cleaned)")
      }
    }
    for f in failures { print("  ENGLISH-CONTROL \(f)") }
    let failureList = failures.joined(separator: "\n")
    #expect(failures.isEmpty, "\(failures.count) English controls regressed:\n\(failureList)")
  }
}
