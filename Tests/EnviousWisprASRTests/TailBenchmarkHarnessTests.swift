import Foundation
import Testing
@preconcurrency import WhisperKit

@testable import EnviousWisprASR

@Suite("Tail benchmark S5 prompt eligibility")
struct TailBenchmarkHarnessTests {
  private actor FakeDecoder: WhisperKitTranscribing {
    private(set) var seenPromptTokens: [[Int]?] = []

    nonisolated func encodeText(_ text: String) -> [Int] { [101, 202] }

    func transcribe(audioArray: [Float], decodeOptions: DecodingOptions?) async throws
      -> [TranscriptionResult]
    {
      seenPromptTokens.append(decodeOptions?.promptTokens)
      return []
    }
  }

  private struct PromptCase: Sendable {
    let conditionOnPriorText: Bool
    let scrolledOutText: String
    let expectedPromptTokens: [Int]?
  }

  @Test(
    "S5 respects every prior-text flag and text combination",
    .bug(
      "https://github.com/saurabhav88/EnviousWispr/issues/1327",
      "S5 benchmark ignored the prior-text flag"))
  func promptEligibilityCrossProduct() async {
    let cases = [
      PromptCase(
        conditionOnPriorText: false, scrolledOutText: "earlier words",
        expectedPromptTokens: nil),
      PromptCase(
        conditionOnPriorText: false, scrolledOutText: "",
        expectedPromptTokens: nil),
      PromptCase(
        conditionOnPriorText: true, scrolledOutText: "earlier words",
        expectedPromptTokens: [101, 202]),
      PromptCase(
        conditionOnPriorText: true, scrolledOutText: "",
        expectedPromptTokens: nil),
    ]

    for testCase in cases {
      var baseOptions = DecodingOptions()
      baseOptions.promptTokens = [999]
      let decoder = FakeDecoder()
      let model = TailBenchmarkModel(
        kit: decoder, baseOptions: baseOptions,
        conditionOnPriorText: testCase.conditionOnPriorText)
      let snapshot = BenchmarkSnapshot(
        samples: [], sampleCount: 0, contentHash: 0, confirmedText: "earlier words",
        lastConfirmedSec: 0, lastDecodeSampleCount: 0, decodeCount: 0,
        totalDecodeTimeMs: 0, unconfirmedSegments: [], bufferStartSec: 0,
        scrolledOutText: testCase.scrolledOutText)

      _ = await TailBenchmarkHarness.armS5(model: model, id: "fixture", snap: snapshot)

      #expect(
        await decoder.seenPromptTokens == [testCase.expectedPromptTokens],
        "condition=\(testCase.conditionOnPriorText) textEmpty=\(testCase.scrolledOutText.isEmpty)")
    }
  }
}
