import CryptoKit
import Foundation
import Testing

@testable import EnviousWisprLLM

private let repoRoot =
  URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()  // LLM
  .deletingLastPathComponent()  // EnviousWisprTests
  .deletingLastPathComponent()  // Tests
  .deletingLastPathComponent()  // repo root

private func artifactText(_ relative: String) throws -> String {
  let url = repoRoot.appendingPathComponent(relative)
  #expect(FileManager.default.fileExists(atPath: url.path), "artifact not found at \(url.path)")
  return try String(contentsOf: url, encoding: .utf8)
}

/// #3195: the Apple polish recipe (v56 instructions, six example turns, correction-gated
/// trailer) and its tracked eval artifacts are one contract.
///
/// The `sealed_v1` numbers that justified v56 (macOS 27 and macOS 26.7) were measured
/// against the FILES (`scripts/eval/prompts/single-v56*.{txt,jsonl}` through the
/// `EW_AFM_*_FILE` seams, which read them verbatim), so if the app ships different bytes
/// every quality number stops describing the app. Same contract `LocalFixedPromptBuilderTests`
/// holds for L3.
@Suite("On-device prompt v56 mirror (#3195)", .tags(.driftGuard))
struct OnDeviceInstructionsV56MirrorTests {

  @Test(
    "Swift instructions are byte-identical to the tracked v56 artifact, trailing newline included")
  func instructionsMatchArtifact() throws {
    let fileText = try artifactText("scripts/eval/prompts/single-v56.txt")
    #expect(fileText.hasSuffix(".\n"), "artifact should end with exactly one trailing newline")
    #expect(fileText == AppleIntelligenceConnector.onDeviceInstructionsV56ForTests)
  }

  @Test("example turns are pair-for-pair identical to the tracked v56 examples artifact")
  func exampleTurnsMatchArtifact() throws {
    let lines = try artifactText("scripts/eval/prompts/single-v56-examples.jsonl")
      .split(separator: "\n")
    let fromFile = try lines.map {
      try JSONDecoder().decode(
        AppleIntelligenceConnector.OnDeviceExampleTurn.self, from: Data($0.utf8))
    }
    #expect(fromFile.count == 6)
    #expect(fromFile == AppleIntelligenceConnector.onDeviceExampleTurnsV56ForTests)
  }

  @Test("trailer is byte-identical to the tracked v56 trailer artifact, leading newline included")
  func trailerMatchesArtifact() throws {
    let fileText = try artifactText("scripts/eval/prompts/single-v56-trailer.txt")
    #expect(fileText.hasPrefix("\nIf the speaker replaced a detail"))
    #expect(fileText == AppleIntelligenceConnector.onDevicePromptTrailerV56)
  }

  @Test("with no bench override the selection is the v56 recipe")
  func defaultSelectionIsV56() {
    let sel = AppleIntelligenceConnector.promptSelection(overrideText: nil)
    #expect(sel.base == AppleIntelligenceConnector.onDeviceInstructionsV56ForTests)
    #expect(sel.exampleTurns == AppleIntelligenceConnector.onDeviceExampleTurnsV56ForTests)
    #expect(sel.trailer == AppleIntelligenceConnector.onDevicePromptTrailerV56)
  }

  @Test("bench overrides replace one part each; an empty examples or trailer override means none")
  func overridesReplaceOnePartEach() {
    let one = [AppleIntelligenceConnector.OnDeviceExampleTurn(input: "a", output: "b")]
    let sel = AppleIntelligenceConnector.promptSelection(
      overrideText: "CANDIDATE", exampleOverride: one, trailerOverride: "\nT")
    #expect(sel.base == "CANDIDATE")
    #expect(sel.exampleTurns == one)
    #expect(sel.trailer == "\nT")
    let none = AppleIntelligenceConnector.promptSelection(
      overrideText: nil, exampleOverride: [], trailerOverride: "")
    #expect(none.base == AppleIntelligenceConnector.onDeviceInstructionsV56ForTests)
    #expect(none.exampleTurns.isEmpty)
    #expect(none.trailer.isEmpty)
  }

  @Test("a blank instructions override is ignored")
  func blankOverrideIgnored() {
    let sel = AppleIntelligenceConnector.promptSelection(overrideText: "  \n")
    #expect(sel.base == AppleIntelligenceConnector.onDeviceInstructionsV56ForTests)
  }

  /// The sealed corpus itself is gitignored (it stays on the dev machine so it remains a
  /// verdict), but `scripts/eval/corpus/sealed_v1_input_hashes.txt` is TRACKED: one SHA-256
  /// per exam input, lowercased and trimmed. That lets this row run on every checkout
  /// and in CI without the exam text leaving this machine (Codex diff review r1 on #2795, P1).
  @Test("no example input is a sealed-exam input (the exam stays a verdict, never a tuning set)")
  func exampleInputsAreNotSealedCases() throws {
    let sealedHashes = Set(
      try artifactText("scripts/eval/corpus/sealed_v1_input_hashes.txt")
        .split(separator: "\n").map(String.init))
    #expect(sealedHashes.count > 1000, "hash list looks truncated: \(sealedHashes.count) entries")
    func digest(_ text: String) -> String {
      let data = Data(text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().utf8)
      return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    for turn in AppleIntelligenceConnector.onDeviceExampleTurnsV56ForTests {
      #expect(
        !sealedHashes.contains(digest(turn.input)), "example is a sealed input: \(turn.input)")
    }
    // Two-way control: a real exam input's digest IS in the list, so an empty or wrong
    // list cannot pass this row vacuously. The control string is the digest of one sealed
    // input, not the input itself.
    #expect(
      sealedHashes.contains("0010411ac09a6341a6eb8faba629efd01b8e15e89372e2e689f22dff2e6d8cd0"))
  }
}

/// #3195: the correction-gated trailer. When these fail, a user's spoken correction is
/// cleaned with a different assembly from the one measured on `sealed_v1`.
@Suite("On-device correction trailer gate (#3195)", .tags(.productOutcome))
struct OnDeviceCorrectionTrailerGateTests {
  private let trailer = AppleIntelligenceConnector.onDevicePromptTrailerV56

  @Test("an empty trailer wraps byte-identically to the pre-#3195 literal")
  func emptyTrailerMatchesOldWrap() {
    let text = "send the report, sorry, the invoice"
    #expect(
      AppleIntelligenceConnector.wrapTranscript(text, trailer: "")
        == "<TRANSCRIPT>\n\(text)\n</TRANSCRIPT>")
  }

  @Test("a correction marker appends the trailer after the closing tag")
  func markerAppendsTrailer() {
    let text = "Send the report to Dev on Tuesday, sorry, on Wednesday."
    #expect(AppleIntelligenceConnector.correctionMarker(in: text) == "sorry")
    #expect(
      AppleIntelligenceConnector.wrapTranscript(text, trailer: trailer)
        == "<TRANSCRIPT>\n\(text)\n</TRANSCRIPT>" + trailer)
  }

  @Test("no marker means no trailer")
  func noMarkerNoTrailer() {
    let text = "okay so the meeting went well and I think we're on track"
    #expect(AppleIntelligenceConnector.correctionMarker(in: text) == nil)
    #expect(
      AppleIntelligenceConnector.wrapTranscript(text, trailer: trailer)
        == "<TRANSCRIPT>\n\(text)\n</TRANSCRIPT>")
  }

  @Test("{MARKER} in a trailer is replaced by the marker found")
  func markerPlaceholderSubstituted() {
    let wrapped = AppleIntelligenceConnector.wrapTranscript(
      "at eight, I mean nine", trailer: " [{MARKER}]")
    #expect(wrapped.hasSuffix("</TRANSCRIPT> [i mean]"))
  }

  @Test(
    "the trailer is armed for English and undetected input only",
    arguments: [
      (String?.none, true), ("en", true), ("es", false), ("de", false),
    ])
  func armedOnlyForEnglish(language: String?, armed: Bool) {
    #expect(
      AppleIntelligenceConnector.armedTrailer(trailer, detectedLanguage: language)
        == (armed ? trailer : ""))
  }

  @Test("a Spanish 'no,' never arms the trailer when the language is detected as Spanish")
  func spanishNoDoesNotArm() {
    let text = "Mándalo el martes, no, el miércoles."
    // The English list does match "no," here, so only the language gate keeps it out.
    #expect(AppleIntelligenceConnector.correctionMarker(in: text) == "no")
    let armed = AppleIntelligenceConnector.armedTrailer(trailer, detectedLanguage: "es")
    #expect(
      AppleIntelligenceConnector.wrapTranscript(text, trailer: armed)
        == "<TRANSCRIPT>\n\(text)\n</TRANSCRIPT>")
  }

  @Test("the measured assembly arms the trailer on example turns 1-4 and not on 5-6")
  func exampleTurnsArmAsMeasured() {
    let armed = AppleIntelligenceConnector.onDeviceExampleTurnsV56ForTests.map {
      AppleIntelligenceConnector.correctionMarker(in: $0.input) != nil
    }
    #expect(armed == [true, true, true, true, false, false])
  }
}
