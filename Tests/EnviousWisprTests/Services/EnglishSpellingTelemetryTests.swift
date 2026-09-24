import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing

#if DEBUG

  /// #3124: `dictation.completed` carries the English (UK) facts only on a British take, as a
  /// closed value and a count, never text. When this fails, the adoption and effectiveness
  /// dashboards for English (UK) lie.
  @Suite("English (UK) on dictation.completed", .serialized, .tags(.observabilityContract))
  struct EnglishSpellingTelemetryTests {
    final class EventBox: @unchecked Sendable {
      private let lock = NSLock()
      private var stored: [CapturedTelemetryEvent] = []
      func append(_ event: CapturedTelemetryEvent) { lock.withLock { stored.append(event) } }
      var values: [CapturedTelemetryEvent] { lock.withLock { stored } }
    }

    @MainActor
    private static func completed(englishSpelling: String?, spellingSwaps: Int?)
      -> [CapturedTelemetryEvent]
    {
      let box = EventBox()
      TelemetryService.shared.testEventHook = { @Sendable event in
        if event.name == "dictation.completed" { box.append(event) }
      }
      defer { TelemetryService.shared.testEventHook = nil }
      TelemetryService.shared.dictationCompleted(
        result: "success", inputMode: "ptt", asrBackend: "parakeet", llmProvider: nil,
        fillerRemoval: false, targetApp: nil, pasteResult: "accessibility",
        e2eSeconds: 1.0, asrSeconds: nil, llmSeconds: nil,
        englishSpelling: englishSpelling, spellingSwaps: spellingSwaps)
      return box.values
    }

    @MainActor
    @Test("a British take reports the preference and the accepted swap count")
    func britishTake() throws {
      let event = try #require(Self.completed(englishSpelling: "british", spellingSwaps: 3).first)
      #expect(event.stringProps["english_spelling"] == "british")
      #expect(event.intProps["spelling_swaps"] == 3)
    }

    @MainActor
    @Test("a British take whose passes did not run reports the preference without a count")
    func britishTakeWithoutPasses() throws {
      let event = try #require(Self.completed(englishSpelling: "british", spellingSwaps: nil).first)
      #expect(event.stringProps["english_spelling"] == "british")
      #expect(event.intProps["spelling_swaps"] == nil)
    }

    /// The hop the app actually uses: a saved transcript's metrics through
    /// `reportDictationCompleted`, so a broken mapping there cannot hide behind the emitter test.
    @MainActor
    @Test("a transcript's spelling metrics reach dictation.completed through reportDictationCompleted")
    func reportedFromTranscriptMetrics() throws {
      func report(_ metrics: ExecutionMetrics) -> [CapturedTelemetryEvent] {
        let box = EventBox()
        TelemetryService.shared.testEventHook = { @Sendable event in
          if event.name == "dictation.completed" { box.append(event) }
        }
        defer { TelemetryService.shared.testEventHook = nil }
        var transcript = Transcript(text: "the colour")
        transcript.metrics = metrics
        TelemetryService.shared.reportDictationCompleted(transcript: transcript, inputMode: "ptt")
        return box.values
      }
      let british = try #require(
        report(ExecutionMetrics(englishSpelling: .british, spellingSwaps: 2)).first)
      #expect(british.stringProps["english_spelling"] == "british")
      #expect(british.intProps["spelling_swaps"] == 2)

      let noCount = try #require(report(ExecutionMetrics(englishSpelling: .british)).first)
      #expect(noCount.stringProps["english_spelling"] == "british")
      #expect(noCount.intProps["spelling_swaps"] == nil)

      let american = try #require(report(ExecutionMetrics()).first)
      #expect(american.stringProps["english_spelling"] == nil)
      #expect(american.intProps["spelling_swaps"] == nil)
    }

    @MainActor
    @Test("an American take carries neither property")
    func americanTake() throws {
      let event = try #require(Self.completed(englishSpelling: nil, spellingSwaps: nil).first)
      #expect(event.stringProps["english_spelling"] == nil)
      #expect(event.intProps["spelling_swaps"] == nil)
    }
  }

#endif
