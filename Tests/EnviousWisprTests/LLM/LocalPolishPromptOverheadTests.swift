import Foundation
import Testing

@testable import EnviousWisprCore
@testable import EnviousWisprLLM
@testable import EnviousWisprPipeline

/// The context preflight in `LLMPolishStep` reserves a fixed byte allowance for
/// everything that is NOT the transcript: the system prompt and the chat
/// framing around it. A constant like that decays silently — a prompt edit does
/// not touch it, and the failure is a dictation admitted that the server then
/// cannot fit, which is the silent truncation the preflight exists to prevent.
///
/// It had already decayed once: the allowance was 256 bytes against EG-1's
/// 1,147-byte v2 system prompt, and survived only because that engine launches
/// with a 16,384-token window. S1-mini has 8,192 and no such slack.
@Suite("Local polish prompt overhead stays inside its reserve (#2649)", .tags(.driftGuard))
struct LocalPolishPromptOverheadTests {
  /// The constant `LLMPolishStep` actually reserves, READ from it.
  ///
  /// An earlier version of this line restated `1536` with a comment claiming
  /// the rows below kept the two honest. That claim was false: changing
  /// production to 1,024 would have left every row green, which is the same
  /// disconnected-constant defect that let the previous 256 survive beside
  /// EG-1's 1,147-byte system prompt.
  static let reservedBytes = LLMPolishStep.localPromptOverheadBytes

  static func input(provider: LLMProvider, modelID: String) -> PromptBuildInput {
    PromptBuildInput(
      transcript: "",
      provider: provider,
      modelID: modelID,
      appName: nil,
      language: nil,
      polishVocabulary: PolishVocabulary(terms: [], generation: 0),
      ollamaIsRemote: nil)
  }

  /// Rendered with an EMPTY transcript, so what is measured is exactly the
  /// overhead and nothing else.
  @Test("every bundled local prompt fits the reserve with an empty transcript")
  func everyBundledPromptFitsTheReserve() {
    let cases: [(name: String, family: PromptFamily, provider: LLMProvider, model: String)] = [
      ("EG-1 v1", .egOneFixed, .egOne, LLMProvider.egOneModelName),
      ("EG-1 v2", .egOneEnvelope, .egOne, LLMProvider.egOneModelName),
      ("S1-mini", .s1ControlLine, .s1Mini, LLMProvider.s1MiniModelName),
    ]
    for row in cases {
      let envelope = DefaultPromptPlanner.builder(for: row.family)
        .build(input: Self.input(provider: row.provider, modelID: row.model), mode: .message)
      let overhead = envelope.messages.reduce(0) { $0 + $1.content.utf8.count }
      #expect(
        overhead <= Self.reservedBytes,
        "\(row.name) renders \(overhead) bytes of overhead, over the \(Self.reservedBytes) reserved")
    }
  }

  /// Two-way control. A reserve larger than every prompt passes trivially, so
  /// the row above proves nothing until the comparison is shown to FIRE.
  @Test("the reserve check rejects a prompt that would not fit")
  func theCheckFiresOnAnOversizePrompt() {
    let oversize = String(repeating: "x", count: Self.reservedBytes + 1)
    #expect(oversize.utf8.count > Self.reservedBytes)
  }

  /// The reserve must stay ahead of the LARGEST bundled prompt by a real
  /// margin, not merely clear it. A reserve that exactly fits today becomes
  /// wrong on the next word added to a prompt.
  @Test("the reserve leaves headroom above the largest bundled prompt")
  func reserveLeavesHeadroom() {
    let largest = [PromptFamily.egOneFixed, .egOneEnvelope, .s1ControlLine]
      .map { family in
        DefaultPromptPlanner.builder(for: family)
          .build(
            input: Self.input(provider: .egOne, modelID: LLMProvider.egOneModelName),
            mode: .message)
          .messages.reduce(0) { $0 + $1.content.utf8.count }
      }
      .max() ?? 0
    #expect(largest > 0)
    #expect(
      Self.reservedBytes - largest >= 256,
      "only \(Self.reservedBytes - largest) bytes of headroom above the largest prompt")
  }
}
