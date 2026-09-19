import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// #3038: the guard's verdict and the token count travel to `llm.polish_completed` as
/// `polish_validator_guard` and `symbol_tokens`, omitted when nil, a measured zero emitted.
/// When this fails a dashboard cannot tell how often polish destroyed a slash on takes that
/// carried one.
@Suite(.tags(.observabilityContract))
@MainActor
struct PolishSymbolGuardTelemetryTests {
  #if DEBUG

    private final class Box: @unchecked Sendable {
      var event: CapturedTelemetryEvent?
    }

    private static func transcript(guardName: String?, symbolTokens: Int?) -> Transcript {
      Transcript(
        text: "hello",
        polishedText: "Hello.",
        llmProvider: "egOne",
        llmModel: "eg-1",
        metrics: ExecutionMetrics(
          asrLatencySeconds: 0.4,
          llmLatencySeconds: 0.3,
          pasteTier: "cgevent",
          pasteLatencyMs: 12,
          e2eSeconds: 1.0,
          polishValidatorGuard: guardName,
          symbolTokens: symbolTokens))
    }

    private func capturePolishCompleted(_ transcript: Transcript) -> CapturedTelemetryEvent? {
      let box = Box()
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated {
          if event.name == "llm.polish_completed" { box.event = event }
        }
      }
      defer { TelemetryService.shared.testEventHook = nil }
      TelemetryService.shared.reportDictationCompleted(transcript: transcript, inputMode: "ptt")
      return box.event
    }

    @Test("A symbol drop reaches the event with its guard name and the measured count")
    func symbolDropReachesTheEvent() throws {
      let event = try #require(capturePolishCompleted(Self.transcript(guardName: "symbol_drop", symbolTokens: 2)))
      #expect(event.stringProps["polish_validator_guard"] == "symbol_drop")
      #expect(event.intProps["symbol_tokens"] == 2)
    }

    @Test("A measured zero is emitted; nil is omitted")
    func zeroEmittedNilOmitted() throws {
      let zero = try #require(capturePolishCompleted(Self.transcript(guardName: nil, symbolTokens: 0)))
      #expect(zero.intProps["symbol_tokens"] == 0)
      #expect(zero.stringProps["polish_validator_guard"] == nil)
      let none = try #require(capturePolishCompleted(Self.transcript(guardName: nil, symbolTokens: nil)))
      #expect(none.intProps["symbol_tokens"] == nil)
      #expect(none.stringProps["polish_validator_guard"] == nil)
    }

    @Test("ExecutionMetrics decodes a pre-#3038 record with both fields absent")
    func legacyDecode() throws {
      let json = #"{"asrLatencySeconds":0.4,"llmLatencySeconds":0.3,"coldStart":false,"streamingMode":false}"#
      let metrics = try JSONDecoder().decode(ExecutionMetrics.self, from: Data(json.utf8))
      #expect(metrics.polishValidatorGuard == nil)
      #expect(metrics.symbolTokens == nil)
      let roundTrip = try JSONDecoder().decode(
        ExecutionMetrics.self,
        from: JSONEncoder().encode(ExecutionMetrics(polishValidatorGuard: "symbol_drop", symbolTokens: 3)))
      #expect(roundTrip.polishValidatorGuard == "symbol_drop")
      #expect(roundTrip.symbolTokens == 3)
    }

  #endif
}
