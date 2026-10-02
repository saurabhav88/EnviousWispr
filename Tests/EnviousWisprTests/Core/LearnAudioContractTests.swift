import EnviousWisprCore
import Foundation
import Testing

/// The take-scoped learn audio contract (#3338 PR-4, K5/K6). Drift guard: when this
/// fails we changed the seam between the recording session, the hold and the nudge,
/// not what the user sees. Production provenance, expiry and release are tested where
/// the hold and the kernel wiring live.
@Suite("Learn audio contract (#3338)", .tags(.driftGuard))
struct LearnAudioContractTests {

  private final class Window: LearnPreparedWindowHandle {}

  @Test("a take without timings or a language option keeps both as nil")
  func absentTimingsAndLanguageStayNil() throws {
    let record = try #require(
      LearnTakeAudio(
        takeID: "take-1", samples: [Float](repeating: 0.1, count: 32_000), decodePath: .streamingRescueBatch, sampleOrigin: .adapterRetainedPCM,
        decodeLanguage: nil, rawText: "send it to Elena", wordTimings: nil))
    #expect(record.wordTimings == nil)
    #expect(record.decodeLanguage == nil)
    #expect(record.sampleOrigin == .adapterRetainedPCM)
    #expect(record.preparedWindows.isEmpty)
    #expect(record.durationMs == 2_000)
  }

  @Test("samples, raw text, timings, path and language are kept exactly")
  func exactPreservation() throws {
    let samples: [Float] = [0.25, -0.5, 0.125, 1.0, -1.0, 0.0, Float.leastNonzeroMagnitude]
    let timings = [
      ASRWordTiming(word: "Kubernetes", range: 0..<10, startMs: 0, endMs: 420),
      ASRWordTiming(word: "now", range: 11..<14, startMs: nil, endMs: nil),
    ]
    let record = try #require(
      LearnTakeAudio(
        takeID: "take-2", samples: samples, decodePath: .conditionedBatch, sampleOrigin: .kernelASRInput, decodeLanguage: "de",
        rawText: "Kubernetes now", wordTimings: timings))
    #expect(record.samples.map(\.bitPattern) == samples.map(\.bitPattern))
    #expect(record.rawText == "Kubernetes now")
    #expect(record.wordTimings == timings)
    #expect(record.decodePath == .conditionedBatch)
    #expect(record.sampleOrigin == .kernelASRInput)
    #expect(record.decodeLanguage == "de")
    #expect(LearnTakeAudio.sampleRate == 16_000)
  }

  @Test("an empty take or take id makes no record")
  func emptyMakesNoRecord() {
    #expect(
      LearnTakeAudio(
        takeID: "t", samples: [], decodePath: .batch, sampleOrigin: .kernelASRInput, decodeLanguage: nil, rawText: "",
        wordTimings: nil)
        == nil)
    #expect(
      LearnTakeAudio(
        takeID: "", samples: [0.1], decodePath: .batch, sampleOrigin: .kernelASRInput, decodeLanguage: nil, rawText: "a",
        wordTimings: nil)
        == nil)
  }

  @Test("prepared window handles keep their identity and are released with the record")
  func handleIdentityAndLifetime() throws {
    weak var weakWindow: Window?
    do {
      let window = Window()
      weakWindow = window
      let record = try #require(
        LearnTakeAudio(
          takeID: "take-3", samples: [0.1, 0.2], decodePath: .batch, sampleOrigin: .kernelASRInput, decodeLanguage: "en",
          rawText: "hi",
          wordTimings: nil, preparedWindows: [window]))
      #expect(record.preparedWindows.count == 1)
      #expect(record.preparedWindows.first === window)
    }
    #expect(weakWindow == nil)
  }
}
