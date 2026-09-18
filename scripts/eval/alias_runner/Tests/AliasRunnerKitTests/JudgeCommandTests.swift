// Harness-contract tests for the `judge` subcommand (#996 Chunk 1).
// Class: harness contract. When these fail the eval INSTRUMENT is wrong;
// they say nothing about judge accuracy. The tag mirrors the root package's
// `TestClassTags` (`Tag` resolves per module, so it is declared once here);
// the root `TestInventoryFreezeTests` does not scan this package.

import Foundation
import Testing

@testable import AliasRunnerKit

extension Tag {
  @Tag static var harnessContract: Self
}

private func row(_ id: String, correction: Bool = true, safe: Bool = true) -> EditCorpusRow {
  let json = """
    {"id":"\(id)","stratum":"person","language":"en","pasted":"send it to Elena","edited":"send it to Alina",
     "original":"Elena","replacement":"Alina","correction":\(correction),"safe_alias":\(safe),"label_source":"test"}
    """
  return try! JSONDecoder().decode(EditCorpusRow.self, from: Data(json.utf8))
}

@Suite("HarnessContract: judge CLI parsing", .tags(.harnessContract))
struct JudgeCLIParseTests {
  @Test("parses the fixture judge with its fixture path")
  func parsesFixture() throws {
    let args = try JudgeCLI.parse(["--corpus", "c.jsonl", "--judge", "fixture", "--fixture", "f.json", "--out", "o.jsonl"])
    #expect(args == JudgeArgs(corpusPath: "c.jsonl", outPath: "o.jsonl", judge: .fixture, fixturePath: "f.json"))
  }

  @Test("every named candidate parses, so an unbuilt judge is a member and not a typo")
  func everyCandidateParses() throws {
    for candidate in JudgeCandidate.allCases where candidate != .fixture {
      let args = try JudgeCLI.parse(["--corpus", "c.jsonl", "--judge", candidate.rawValue])
      #expect(args.judge == candidate)
    }
  }

  @Test("unknown judge, missing corpus, missing judge and stray flags are refused by name")
  func refusals() {
    #expect(throws: JudgeArgsError.unknownJudge("j9")) {
      try JudgeCLI.parse(["--corpus", "c", "--judge", "j9"])
    }
    // The dropped candidates (the user's Ollama polish model, the user's
    // cloud provider) are unknown names, never silently mapped.
    #expect(throws: JudgeArgsError.unknownJudge("j4-ollama")) {
      try JudgeCLI.parse(["--corpus", "c", "--judge", "j4-ollama"])
    }
    #expect(throws: JudgeArgsError.unknownJudge("j5-cloud-provider")) {
      try JudgeCLI.parse(["--corpus", "c", "--judge", "j5-cloud-provider"])
    }
    #expect(throws: JudgeArgsError.missingCorpus) { try JudgeCLI.parse(["--judge", "fixture", "--fixture", "f"]) }
    #expect(throws: JudgeArgsError.missingJudge) { try JudgeCLI.parse(["--corpus", "c"]) }
    #expect(throws: JudgeArgsError.unknownArgument("--disable-timeout")) {
      try JudgeCLI.parse(["--corpus", "c", "--judge", "rules", "--disable-timeout"])
    }
    #expect(throws: JudgeArgsError.missingValue("--out")) { try JudgeCLI.parse(["--corpus", "c", "--judge", "rules", "--out"]) }
  }

  @Test("fixture judge needs a fixture path and other judges refuse one")
  func fixturePairing() {
    #expect(throws: JudgeArgsError.fixtureRequiresFixturePath) { try JudgeCLI.parse(["--corpus", "c", "--judge", "fixture"]) }
    #expect(throws: JudgeArgsError.fixturePathOnlyWithFixtureJudge) {
      try JudgeCLI.parse(["--corpus", "c", "--judge", "rules", "--fixture", "f"])
    }
  }
}

@Suite("HarnessContract: corpus loading", .tags(.harnessContract))
struct EditCorpusLoadTests {
  @Test("decodes rows with snake_case keys and rejects duplicates, bad lines and emptiness")
  func loading() throws {
    let good = """
      {"id":"a","stratum":"person","language":"en","pasted":"p","edited":"e","original":"o","replacement":"r","correction":true,"safe_alias":false,"label_source":"t"}

      {"id":"b","stratum":"brand","language":"de","pasted":"p","edited":"e","original":"o","replacement":"r","correction":false,"safe_alias":false,"label_source":"t"}
      """
    let rows = try EditCorpus.load(text: good)
    #expect(rows.map(\.id) == ["a", "b"])
    #expect(rows[0].safeAlias == false)
    #expect(rows[1].correction == false)

    #expect(throws: CorpusLoadError.duplicateID("a")) {
      try EditCorpus.load(text: good.replacingOccurrences(of: "\"id\":\"b\"", with: "\"id\":\"a\""))
    }
    #expect(throws: CorpusLoadError.empty) { try EditCorpus.load(text: "\n\n") }
    do {
      _ = try EditCorpus.load(text: "{\"id\":\"x\"}")
      Issue.record("a row missing required keys decoded")
    } catch CorpusLoadError.badLine(let n, _) {
      #expect(n == 1)
    }
  }
}

@Suite("HarnessContract: fixture executor", .tags(.harnessContract))
struct JudgeFixtureTests {
  @Test("a decision entry yields a verdict, a bypass entry yields that bypass, a missing entry is malformed")
  func outcomes() throws {
    let fixture = try JudgeFixture.load(
      from: Data(
        """
        {"a":{"vocabulary_correction":true,"safe_alias":false},"b":{"outcome":"deadline"}}
        """.utf8))
    var tick = 0.0
    let records = JudgeRunner.run(rows: [row("a"), row("b"), row("c")], fixture: fixture, clock: { tick += 5; return tick })
    #expect(records.map(\.outcome) == [.verdict, .deadline, .malformed])
    #expect(records[0].decision == JudgeDecision(vocabularyCorrection: true, safeAlias: false))
    #expect(records[1].decision == nil)
    #expect(records[2].note == "fixture has no entry for this row")
    // Latency is the injected clock's delta, so the column is real and testable.
    #expect(records.allSatisfy { $0.latencyMs == 5 })
    #expect(records.allSatisfy { $0.judge == "fixture" })
  }

  @Test("a fixture entry naming `verdict` as an outcome, or missing a boolean, is refused at load")
  func badEntries() {
    #expect(throws: JudgeFixture.FixtureError.badEntry(id: "a", reason: "outcome must be a bypass name, got verdict")) {
      try JudgeFixture.load(from: Data("{\"a\":{\"outcome\":\"verdict\"}}".utf8))
    }
    #expect(throws: JudgeFixture.FixtureError.badEntry(id: "a", reason: "entry needs both booleans or an outcome")) {
      try JudgeFixture.load(from: Data("{\"a\":{\"vocabulary_correction\":true}}".utf8))
    }
  }

  @Test("an unimplemented judge writes one explicit row per corpus row and never a verdict")
  func unimplemented() {
    let records = JudgeRunner.unimplemented(rows: [row("a"), row("b")], judge: .afmMacOS27)
    #expect(records.count == 2)
    #expect(records.allSatisfy { $0.outcome == .unimplemented && $0.decision == nil && $0.judge == "afm-macos27" })
    #expect(records.allSatisfy { $0.note == "judge afm-macos27 is not implemented in this build" })
  }

  @Test("the deferred Qwen arm is a member that says it is deferred, not merely unbuilt")
  func deferredArm() {
    #expect(JudgeCandidate.qwen3_0_6B.status == .deferred)
    let records = JudgeRunner.unimplemented(rows: [row("a")], judge: .qwen3_0_6B)
    #expect(records.map(\.outcome) == [.unimplemented])
    #expect(records[0].note == "judge qwen3-0.6b-q4 is deferred by plan §2.2; not built in this build")
  }

  @Test("the candidate set is the revised plan §2.2 set: fixture, rules, two AFM arms, three cross-encoders, deferred Qwen")
  func candidateSet() {
    #expect(JudgeCandidate.allCases.map(\.rawValue) == [
      "fixture", "rules", "afm-macos26", "afm-macos27",
      "xenc-mmbert-small", "xenc-mdeberta-v3-base", "xenc-xlmr-base", "qwen3-0.6b-q4",
    ])
    #expect(JudgeCandidate.allCases.filter { $0.status == .fixture } == [.fixture])
    #expect(JudgeCandidate.allCases.filter { $0.status == .deferred } == [.qwen3_0_6B])
    #expect(JudgeCandidate.allCases.filter { $0.status == .unimplemented }.count == 6)
  }

  @Test("records encode with sorted snake_case keys, one JSON object per line")
  func encoding() throws {
    let text = try JudgeCLI.encode([
      JudgeRecord(id: "a", judge: "fixture", outcome: .verdict,
        decision: JudgeDecision(vocabularyCorrection: true, safeAlias: true), latencyMs: 1.5, note: nil)
    ])
    #expect(text == "{\"decision\":{\"safe_alias\":true,\"vocabulary_correction\":true},\"id\":\"a\",\"judge\":\"fixture\",\"latency_ms\":1.5,\"outcome\":\"verdict\"}\n")
  }

  @Test("execution identity is encoded when a judge derives one and omitted for an unexecuted record")
  func executionIdentityEncoding() throws {
    let executed = JudgeRecord(
      id: "a", judge: "xenc-xlmr-base", outcome: .verdict,
      decision: JudgeDecision(vocabularyCorrection: true, safeAlias: false), latencyMs: 2,
      note: nil, executionIdentity: ["checkpoint_sha256": "abc", "tokenizer_sha256": "def"])
    let text = try JudgeCLI.encode([executed])
    #expect(text.contains("\"execution_identity\":{\"checkpoint_sha256\":\"abc\",\"tokenizer_sha256\":\"def\"}"))
    let unexecuted = JudgeRunner.unimplemented(rows: [row("a")], judge: .rules)
    #expect(unexecuted[0].executionIdentity == nil)
    #expect(try JudgeCLI.encode(unexecuted).contains("execution_identity") == false)
    let fixtureRecords = JudgeRunner.run(
      rows: [row("a")], fixture: JudgeFixture(entries: ["a": .decision(JudgeDecision(vocabularyCorrection: true, safeAlias: true))]))
    #expect(fixtureRecords[0].executionIdentity == nil)
  }
}

@Suite("HarnessContract: execute end to end on temp files", .tags(.harnessContract))
struct JudgeExecuteTests {
  @Test("fixture judge exits 0 with records; a named unbuilt judge exits 3 with unimplemented records; a bad corpus exits 2")
  func exitCodes() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("judge-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let corpus = dir.appendingPathComponent("c.jsonl")
    let fixture = dir.appendingPathComponent("f.json")
    try """
      {"id":"a","stratum":"person","language":"en","pasted":"p","edited":"e","original":"o","replacement":"r","correction":true,"safe_alias":true,"label_source":"t"}
      """.write(to: corpus, atomically: true, encoding: .utf8)
    try "{\"a\":{\"vocabulary_correction\":true,\"safe_alias\":true}}".write(to: fixture, atomically: true, encoding: .utf8)

    let ok = await JudgeCLI.execute(args: JudgeArgs(corpusPath: corpus.path, outPath: nil, judge: .fixture, fixturePath: fixture.path))
    #expect(ok.exitCode == 0)
    #expect(ok.records.map(\.outcome) == [.verdict])

    let unbuilt = await JudgeCLI.execute(args: JudgeArgs(corpusPath: corpus.path, outPath: nil, judge: .rules, fixturePath: nil))
    #expect(unbuilt.exitCode == 3)
    #expect(unbuilt.records.map(\.outcome) == [.unimplemented])

    let bad = await JudgeCLI.execute(args: JudgeArgs(corpusPath: dir.appendingPathComponent("missing.jsonl").path, outPath: nil, judge: .fixture, fixturePath: fixture.path))
    #expect(bad.exitCode == 2)
    #expect(bad.records.isEmpty)
  }

  @Test("a candidate with a wired arm runs every row through it, in order, and exits 0")
  func armDispatch() async throws {
    struct EchoArm: JudgeArm {
      func judge(row: EditCorpusRow) async -> JudgeRecord {
        JudgeRecord(
          id: row.id, judge: JudgeCandidate.rules.rawValue, outcome: .verdict,
          decision: JudgeDecision(vocabularyCorrection: row.correction, safeAlias: row.safeAlias),
          latencyMs: 1, note: nil, executionIdentity: ["config_sha256": "x", "environment": "test"])
      }
    }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("judge-arm-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let corpus = dir.appendingPathComponent("c.jsonl")
    try """
      {"id":"a","stratum":"person","language":"en","pasted":"p","edited":"e","original":"o","replacement":"r","correction":true,"safe_alias":true,"label_source":"t"}
      {"id":"b","stratum":"person","language":"en","pasted":"p2","edited":"e2","original":"o2","replacement":"r2","correction":false,"safe_alias":false,"label_source":"t"}
      """.write(to: corpus, atomically: true, encoding: .utf8)
    let result = await JudgeCLI.execute(
      args: JudgeArgs(corpusPath: corpus.path, outPath: nil, judge: .rules, fixturePath: nil),
      arms: [.rules: EchoArm()])
    #expect(result.exitCode == 0)
    #expect(result.records.map(\.id) == ["a", "b"])
    #expect(result.records.map(\.outcome) == [.verdict, .verdict])
    #expect(result.records[0].executionIdentity?["environment"] == "test")
    // The arm is keyed by candidate: asking for another candidate stays unimplemented.
    let other = await JudgeCLI.execute(
      args: JudgeArgs(corpusPath: corpus.path, outPath: nil, judge: .afmMacOS27, fixturePath: nil),
      arms: [.rules: EchoArm()])
    #expect(other.exitCode == 3)
    #expect(other.records.map(\.outcome) == [.unimplemented, .unimplemented])
  }
}
