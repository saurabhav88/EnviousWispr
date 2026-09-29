import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprLLM

/// #3275: the on-device concern split's own decisions (fit, language) and its hand-off to the
/// help check. The model itself is exercised by the benchmark kit, not here.
@Suite("Help concern split (#3275)", .tags(.productOutcome))
struct HelpConcernDecomposerTests {

  @Test(
    "A full 4,000-character message fits macOS 26's 4,096-token window; a longer prompt does not")
  func contextFit() {
    // 4,000 Latin characters by the connector's conservative estimate: about 1,334 tokens.
    let message = String(repeating: "paste fails ", count: 334).prefix(4000)
    let prompt = HelpConcernDecomposer.prompt(for: String(message))
    let promptTokens = AppleIntelligenceConnector.heuristicAFMTokens(prompt, lang: "en")
    let instructionTokens = AppleIntelligenceConnector.heuristicAFMTokens(
      HelpConcernDecomposer.instructions, lang: nil)
    #expect(
      HelpConcernDecomposer.fits(
        instructionTokens: instructionTokens, promptTokens: promptTokens, contextTokens: 4096))
    // The same arithmetic at the boundary: one token too many does not fit.
    let room =
      4096 - HelpConcernDecomposer.reservedTokens
      - AppleIntelligenceConnector.afmContextSafetyMarginTokens
    #expect(
      HelpConcernDecomposer.fits(instructionTokens: 0, promptTokens: room, contextTokens: 4096))
    #expect(
      !HelpConcernDecomposer.fits(instructionTokens: 0, promptTokens: room + 1, contextTokens: 4096)
    )
    // 4,000 unsegmented characters (about one token each) do not fit macOS 26 and go whole-message.
    let cjk = String(repeating: "粘贴失败", count: 1000)
    let cjkTokens = AppleIntelligenceConnector.heuristicAFMTokens(
      HelpConcernDecomposer.prompt(for: cjk), lang: "zh")
    #expect(
      !HelpConcernDecomposer.fits(
        instructionTokens: instructionTokens, promptTokens: cjkTokens, contextTokens: 4096))
  }

  @Test("The whole message is split, never a prefix of it")
  func noTruncation() {
    let message = String(repeating: "a", count: 3999) + "Z"
    #expect(HelpConcernDecomposer.prompt(for: message).hasSuffix("Z"))
  }

  @Test("Short or unknown text is not judged by language; an unsupported language fails")
  func languageGate() {
    #expect(HelpConcernDecomposer.languageIsSupported(nil, supported: ["en"]))
    #expect(HelpConcernDecomposer.languageIsSupported("de", supported: ["en", "de"]))
    #expect(!HelpConcernDecomposer.languageIsSupported("hi", supported: ["en", "de"]))
    #expect(HelpConcernDecomposer.detectedBase("paste fails") == nil)
    #expect(
      HelpConcernDecomposer.detectedBase(
        "Seit dem Update startet die Aufnahme, aber es wird nichts in Slack eingefügt.") == "de")
  }

  @Test("Every split outcome reaches the help check; an unknown kind is kept as other")
  func wiring() {
    let concern = HelpConcernDecomposer.Concern(summary: "s", evidence: "e", kind: "rant")
    #expect(
      HelpCheckWiring.decomposition(.concerns([concern], hitCap: true))
        == .concerns([HelpCheckConcern(summary: "s", evidence: "e", kind: .other)], hitCap: true))
    #expect(HelpCheckWiring.decomposition(.failed(.unavailable)) == .unavailable(.afmUnavailable))
    #expect(
      HelpCheckWiring.decomposition(.failed(.unsupportedLanguage)) == .unavailable(.afmUnavailable))
    #expect(HelpCheckWiring.decomposition(.failed(.tooLong)) == .unavailable(.afmUnavailable))
    #expect(HelpCheckWiring.decomposition(.failed(.refused)) == .unavailable(.afmRefused))
    #expect(HelpCheckWiring.decomposition(.failed(.error)) == .unavailable(.afmError))
  }
}
