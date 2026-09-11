import CryptoKit
import Foundation
import Testing

@testable import EnviousWisprLLM

/// #2795: the macOS 27+ Apple prompt (v39) and its tracked eval artifact are one
/// contract, and the OS gate that selects it is a pure function.
///
/// The sealed-exam number that justified v39 was measured against the FILE
/// (`scripts/eval/prompts/single-v39.txt`, through `EW_AFM_PROMPT_FILE`), so if
/// the app ships different bytes every quality number stops describing the app.
/// Same contract `LocalFixedPromptBuilderTests` holds for L3.
@Suite("On-device prompt v39 mirror and OS gate (#2795)", .tags(.driftGuard))
struct OnDeviceInstructionsV39MirrorTests {

  @Test("Swift literal is byte-identical to the tracked v39 artifact")
  func literalMatchesArtifact() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    // Tests/EnviousWisprTests/LLM/<this file> -> repo root
    let repoRoot =
      testFile
      .deletingLastPathComponent()  // LLM
      .deletingLastPathComponent()  // EnviousWisprTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // repo root
    let artifact = repoRoot.appendingPathComponent("scripts/eval/prompts/single-v39.txt")

    #expect(
      FileManager.default.fileExists(atPath: artifact.path),
      "v39 artifact not found at \(artifact.path)")

    let fileText = try String(contentsOf: artifact, encoding: .utf8)
    #expect(fileText.hasSuffix("\n"), "artifact should end with exactly one trailing newline")
    #expect(
      String(fileText.dropLast()) == AppleIntelligenceConnector.onDeviceInstructionsV39ForTests)
  }

  @Test("macOS 26 gets v38 plus the suffix, byte-identical to the pre-#2795 assembly")
  func macOS26KeepsV38AndSuffix() {
    let sel = AppleIntelligenceConnector.promptSelection(
      majorVersion: 26, overrideText: nil, suffix: "\nSUFFIX")
    #expect(sel.base == AppleIntelligenceConnector.onDeviceInstructionsForTests)
    #expect(sel.suffix == "\nSUFFIX")
    #expect(sel.exampleTurns.isEmpty)
  }

  @Test("macOS 27 gets v39 and no suffix")
  func macOS27GetsV39WithoutSuffix() {
    let sel = AppleIntelligenceConnector.promptSelection(
      majorVersion: 27, overrideText: nil, suffix: "\nSUFFIX")
    #expect(sel.base == AppleIntelligenceConnector.onDeviceInstructionsV39ForTests)
    #expect(sel.suffix == "")
    #expect(sel.exampleTurns == AppleIntelligenceConnector.onDeviceExampleTurnsV39ForTests)
    #expect(sel.exampleTurns.count == 6)
  }

  @Test(
    "a non-empty override replaces the base on either OS and keeps that OS's suffix decision",
    arguments: [(26, "\nSUFFIX"), (27, "")])
  func overrideReplacesBaseOnly(majorVersion: Int, expectedSuffix: String) {
    let sel = AppleIntelligenceConnector.promptSelection(
      majorVersion: majorVersion, overrideText: "CANDIDATE", suffix: "\nSUFFIX")
    #expect(sel.base == "CANDIDATE")
    #expect(sel.suffix == expectedSuffix)
  }

  @Test("a blank override is ignored")
  func blankOverrideIgnored() {
    let sel = AppleIntelligenceConnector.promptSelection(
      majorVersion: 27, overrideText: "  \n", suffix: "")
    #expect(sel.base == AppleIntelligenceConnector.onDeviceInstructionsV39ForTests)
  }

  @Test("v39 carries no emoji instruction either (#1085 guard extends to the new prompt)")
  func v39OmitsEmojiInstruction() {
    #expect(
      AppleIntelligenceConnector.onDeviceInstructionsV39ForTests
        .localizedCaseInsensitiveContains("emoji") == false)
  }
  @Test("an examples override replaces the turns on 27+ only; an empty override means no turns")
  func examplesOverride() {
    let one = [AppleIntelligenceConnector.OnDeviceExampleTurn(input: "a", output: "b")]
    let on27 = AppleIntelligenceConnector.promptSelection(
      majorVersion: 27, overrideText: nil, exampleOverride: one, suffix: "")
    #expect(on27.exampleTurns == one)
    let on26 = AppleIntelligenceConnector.promptSelection(
      majorVersion: 26, overrideText: nil, exampleOverride: one, suffix: "")
    #expect(on26.exampleTurns.isEmpty, "macOS 26 never seeds turns, even under a bench override")
    let none = AppleIntelligenceConnector.promptSelection(
      majorVersion: 27, overrideText: nil, exampleOverride: [], suffix: "")
    #expect(none.exampleTurns.isEmpty)
  }

  @Test("example turns are pair-for-pair identical to the tracked v39 examples artifact")
  func exampleTurnsMatchArtifact() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let repoRoot =
      testFile
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let artifact = repoRoot.appendingPathComponent("scripts/eval/prompts/single-v39-examples.jsonl")
    #expect(
      FileManager.default.fileExists(atPath: artifact.path),
      "v39 examples artifact not found at \(artifact.path)")
    let lines = try String(contentsOf: artifact, encoding: .utf8).split(separator: "\n")
    let fromFile = try lines.map {
      try JSONDecoder().decode(
        AppleIntelligenceConnector.OnDeviceExampleTurn.self, from: Data($0.utf8))
    }
    #expect(fromFile.count == 6)
    #expect(fromFile == AppleIntelligenceConnector.onDeviceExampleTurnsV39ForTests)
  }

  /// The sealed corpus itself is gitignored (it stays on the dev machine so it remains a
  /// verdict), but `scripts/eval/corpus/sealed_v1_input_hashes.txt` is TRACKED: one SHA-256
  /// per exam input, lowercased and trimmed. That lets this row run on every checkout
  /// and in CI without the exam text leaving this machine (Codex diff review r1, P1).
  @Test("no example input is a sealed-exam input (the exam stays a verdict, never a tuning set)")
  func exampleInputsAreNotSealedCases() throws {
    let hashesFile =
      URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("scripts/eval/corpus/sealed_v1_input_hashes.txt")
    #expect(
      FileManager.default.fileExists(atPath: hashesFile.path),
      "tracked hash list missing at \(hashesFile.path)")
    let sealedHashes = Set(
      try String(contentsOf: hashesFile, encoding: .utf8).split(separator: "\n").map(String.init))
    #expect(sealedHashes.count > 1000, "hash list looks truncated: \(sealedHashes.count) entries")
    func digest(_ text: String) -> String {
      let data = Data(text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().utf8)
      return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    for turn in AppleIntelligenceConnector.onDeviceExampleTurnsV39ForTests {
      #expect(!sealedHashes.contains(digest(turn.input)), "example is a sealed input: \(turn.input)")
    }
    // Two-way control: a real exam input's digest IS in the list, so an empty or wrong
    // list cannot pass this row vacuously. The control string is the digest of one sealed
    // input, not the input itself.
    #expect(sealedHashes.contains("0010411ac09a6341a6eb8faba629efd01b8e15e89372e2e689f22dff2e6d8cd0"))
  }
}
