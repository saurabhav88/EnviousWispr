import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// #3147 §3.1: the dictation kernel hands a take's audio to History's saved recordings only when
/// the take completed AND its ordinary permanent save returned successfully, with the raw
/// capture and the recording preference read once at take start. When these fail, a cancelled
/// or failed dictation keeps a recording, a held Escape Recovery take gets one, a mid-take
/// settings change is ignored or misapplied, or the wrong take's audio lands on a row.
///
/// Drives the real kernel through the scenario inventory; only the sink and the save receipt
/// are stood in for.
@MainActor
@Suite("Kernel hands saved dictations to recordings (#3147)", .tags(.productOutcome))
struct KernelDictationRecordingTests {

  final class SinkLog: DictationRecordingSink {
    var requests: [DictationRecordingRequest] = []
    func submit(_ request: DictationRecordingRequest) { requests.append(request) }
  }

  /// The recording preference as the kernel reads it: `values` answer in turn, then the last one.
  @MainActor final class Preference {
    var values: [Bool]
    private(set) var reads = 0
    init(_ values: [Bool]) { self.values = values }
    func read() -> Bool {
      reads += 1
      return values.count > 1 ? values.removeFirst() : values[0]
    }
  }

  /// Answers the kernel's receipt question the way production does in kind: yes only for a row
  /// this kernel actually stored, and never while `refuses` models a failed or pending save.
  @MainActor final class Receipt {
    weak var wrapper: KernelRecordingSession?
    var refuses = false
    private(set) var asked: [UUID] = []
    func answer(_ rowID: UUID) -> Bool {
      asked.append(rowID)
      return !refuses && (wrapper?.storedTranscriptIDs.contains(rowID) ?? false)
    }
  }

  private func context(sink: SinkLog, preference: Preference, receipt: Receipt) -> SimulatorContext {
    let clock = FakeClock()
    let engine = FakeEngine(behavior: .batchSuccess(text: "default"), clock: clock)
    let capture = FakeAudioCapture()
    let vad = FakeVADSignalSource()
    let paste = FakePasteTarget()
    let wrapper = KernelRecordingSession(
      engine: engine, capture: capture, vad: vad, clock: clock, paste: paste,
      recordingPreference: { preference.read() }, recordingSink: sink,
      permanentSaveReceipt: { receipt.answer($0) })
    receipt.wrapper = wrapper
    return SimulatorContext(
      sut: wrapper, engine: engine, capture: capture, vad: vad, clock: clock, paste: paste)
  }

  private static func scenario(_ id: String) -> Scenario {
    guard let found = ScenarioInventory.all.first(where: { $0.id == id }) else {
      fatalError("scenario \(id) missing from the inventory")
    }
    return found
  }

  typealias Source = DictationASREvidence.Source
  typealias Input = DictationASREvidence.DecodeInput

  /// (scenario, what it drives, hand-offs expected when the save succeeded, the delivering
  /// decode's source and input when it is fixed by the scenario).
  nonisolated static let matrix: [(String, String, Int, Source?, Input?)] = [
    ("A1", "batch success", 1, .batch, .conditionedBatch),
    ("A2", "streaming success", 1, .streaming, .rawCapture),
    ("A23", "Phase 2 retry rescue", 1, .phase2Retry, .conditionedBatch),
    ("C5", "salvaged audio interruption", 1, nil, nil),
    ("L5", "cancel during finalizing (safe point)", 1, .batch, .conditionedBatch),
    ("A7", "cancel while recording", 0, nil, nil),
    ("A8", "cancel while transcribing", 0, nil, nil),
    ("A12", "empty result, no speech", 0, nil, nil),
    ("A14", "failure, retry exhausted", 0, nil, nil),
    ("C3", "capture stall, no transport", 0, nil, nil),
  ]

  @Test("each exit hands over the saved take's own audio exactly as expected", arguments: matrix)
  func exitMatrix(_ row: (String, String, Int, Source?, Input?)) async throws {
    let (id, exit, expected, source, input) = row
    let sink = SinkLog()
    let receipt = Receipt()
    let ctx = context(sink: sink, preference: Preference([true]), receipt: receipt)
    let wrapper = try #require(ctx.sut as? KernelRecordingSession)

    let result = await ScenarioRunner().run(Self.scenario(id), context: ctx)

    #expect(result.passed, "\(id) must still pass: \(result.failures)")
    #expect(sink.requests.count == expected, "\(exit): \(sink.requests.count) hand-offs")
    if let request = sink.requests.first {
      #expect(request.rowID == wrapper.storedTranscriptIDs.last, "the row this take saved")
      #expect(request.samples == ctx.capture.capturedSamples, "the raw capture, not a decode buffer")
      #expect(!request.samples.isEmpty)
      #expect(request.recordingsOn)
      // The delivering decode's own text (identity text processing here), never a failed
      // primary attempt's.
      #expect(request.asr.text == wrapper.effects.transcript, "\(exit): the delivered decode's text")
      if let source { #expect(request.asr.source == source, "\(exit)") }
      if let input { #expect(request.asr.input == input, "\(exit)") }
      // The fakes return no word timings, and a streaming win never has them.
      #expect(request.asr.wordTimingsAvailable == false)
    }
  }

  @Test("provenance: word timings count only for a conditioned batch decode with timed text")
  func evidenceMapping() {
    let timed = ASRResult(
      text: "hello there", language: nil, duration: 1, processingTime: 0.1, backendType: .parakeet,
      wordTimings: [ASRWordTiming(word: "hello", range: 0..<5, startMs: 0, endMs: 300)],
      wordTimingCoverage: ASRWordTimingCoverage(timed: 5, total: 10))
    let untimed = ASRResult(
      text: "hello there", language: nil, duration: 1, processingTime: 0.1, backendType: .parakeet)

    let salvage = RecordingSessionKernel.evidence(
      timed, source: .leadSalvage, input: .conditionedBatchTrimmed(leadSamples: 6_400))
    #expect(salvage.input == .conditionedBatchTrimmed(leadSamples: 6_400))
    #expect(salvage.source == .leadSalvage)
    #expect(salvage.wordTimingsAvailable)
    #expect(RecordingSessionKernel.evidence(timed, source: .batch, input: .conditionedBatch).wordTimingsAvailable)
    #expect(!RecordingSessionKernel.evidence(timed, source: .streaming, input: .rawCapture).wordTimingsAvailable)
    #expect(!RecordingSessionKernel.evidence(timed, source: .batch, input: .paddedRawCapture).wordTimingsAvailable)
    #expect(!RecordingSessionKernel.evidence(untimed, source: .batch, input: .conditionedBatch).wordTimingsAvailable)
  }

  @Test("a take whose save gave no receipt (failed or held) is never handed over")
  func noReceiptNoHandOff() async throws {
    let sink = SinkLog()
    let receipt = Receipt()
    receipt.refuses = true
    let ctx = context(sink: sink, preference: Preference([true]), receipt: receipt)

    let result = await ScenarioRunner().run(Self.scenario("A1"), context: ctx)

    #expect(result.passed, "A1 must still pass: \(result.failures)")
    #expect(receipt.asked.count == 1, "the completed take asked for its receipt")
    #expect(sink.requests.isEmpty)
  }

  @Test("the recording preference is read once, at take start, and that value is handed over")
  func preferenceFrozenAtStart() async throws {
    let sink = SinkLog()
    // On when the take starts; any later read would say off.
    let preference = Preference([true, false])
    let ctx = context(sink: sink, preference: preference, receipt: Receipt())

    let result = await ScenarioRunner().run(Self.scenario("A1"), context: ctx)

    #expect(result.passed, "A1 must still pass: \(result.failures)")
    #expect(preference.reads == 1)
    #expect(sink.requests.map(\.recordingsOn) == [true])
  }

  @Test("a take started with recordings off is handed over as off, for the reason to be kept")
  func offTakeIsHandedOverAsOff() async throws {
    let sink = SinkLog()
    let ctx = context(sink: sink, preference: Preference([false]), receipt: Receipt())

    let result = await ScenarioRunner().run(Self.scenario("A1"), context: ctx)

    #expect(result.passed, "A1 must still pass: \(result.failures)")
    #expect(sink.requests.map(\.recordingsOn) == [false])
  }
}
