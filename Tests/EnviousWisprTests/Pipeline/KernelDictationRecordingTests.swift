import EnviousWisprCore
import EnviousWisprStorage
import Foundation
import Testing

@testable import EnviousWisprAppKit
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

  private func context(
    sink: SinkLog, preference: Preference, receipt: Receipt,
    behavior: FakeEngineBehavior = .batchSuccess(text: "default")
  ) -> SimulatorContext {
    let clock = FakeClock()
    let engine = FakeEngine(behavior: behavior, clock: clock)
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
      #expect(request.asr.timing == nil, "\(exit): no word timings, so no timing evidence")
    }
  }

  @Test("provenance: word timings count only for a conditioned batch decode with timed text")
  func evidenceMapping() throws {
    let timed = ASRResult(
      text: "hello there", language: nil, duration: 1, processingTime: 0.1, backendType: .parakeet,
      wordTimings: [ASRWordTiming(word: "hello", range: 0..<5, startMs: 0, endMs: 300)],
      wordTimingCoverage: ASRWordTimingCoverage(timed: 5, total: 10))
    let untimed = ASRResult(
      text: "hello there", language: nil, duration: 1, processingTime: 0.1, backendType: .parakeet)
    let map = [
      DictationAudioTimelineSpan(decodeRange: 0..<8_000, recordingStartSample: 1_000),
      DictationAudioTimelineSpan(decodeRange: 8_000..<16_000, recordingStartSample: 20_000),
    ]

    let salvage = RecordingSessionKernel.evidence(
      timed, source: .leadSalvage, input: .conditionedBatchTrimmed(leadSamples: 6_400),
      timeline: map)
    #expect(salvage.input == .conditionedBatchTrimmed(leadSamples: 6_400))
    #expect(salvage.source == .leadSalvage)
    #expect(salvage.wordTimingsAvailable)
    // The salvage decoded the buffer without its first 6,400 samples: its map is shifted.
    #expect(
      try #require(salvage.timing).timeline == [
        DictationAudioTimelineSpan(decodeRange: 0..<1_600, recordingStartSample: 7_400),
        DictationAudioTimelineSpan(decodeRange: 1_600..<9_600, recordingStartSample: 20_000),
      ])
    let batch = RecordingSessionKernel.evidence(
      timed, source: .batch, input: .conditionedBatch, timeline: map)
    #expect(batch.wordTimingsAvailable)
    let batchTiming = try #require(batch.timing)
    #expect(batchTiming.timeline == map)
    #expect(batchTiming.words == timed.wordTimings)
    #expect(batchTiming.sampleRate == 16_000)

    // A streaming win and Whisper read raw audio: no timing evidence, whatever the result says.
    let streaming = RecordingSessionKernel.evidence(
      timed, source: .streaming, input: .rawCapture, timeline: map)
    #expect(streaming.wordTimingsAvailable == false)
    #expect(streaming.timing == nil)
    let whisper = RecordingSessionKernel.evidence(
      timed, source: .batch, input: .paddedRawCapture, timeline: map)
    #expect(whisper.wordTimingsAvailable == false)
    #expect(whisper.timing == nil)
    let noTimings = RecordingSessionKernel.evidence(
      untimed, source: .batch, input: .conditionedBatch, timeline: map)
    #expect(noTimings.wordTimingsAvailable == false)
    #expect(noTimings.timing == nil)
  }

  @Test("a lead trim drops the stretches it removes and shortens the one it cuts")
  func trimmedTimelineCoordinates() {
    let map = [
      DictationAudioTimelineSpan(decodeRange: 0..<1_000, recordingStartSample: 500),
      DictationAudioTimelineSpan(decodeRange: 1_000..<3_000, recordingStartSample: 4_000),
      DictationAudioTimelineSpan(decodeRange: 3_000..<4_000, recordingStartSample: 9_000),
    ]
    #expect(
      RecordingSessionKernel.trimmedTimeline(map, leadSamples: 1_500) == [
        DictationAudioTimelineSpan(decodeRange: 0..<1_500, recordingStartSample: 4_500),
        DictationAudioTimelineSpan(decodeRange: 1_500..<2_500, recordingStartSample: 9_000),
      ])
    // A cut exactly on a stretch boundary keeps the next stretch whole.
    #expect(
      RecordingSessionKernel.trimmedTimeline(map, leadSamples: 3_000) == [
        DictationAudioTimelineSpan(decodeRange: 0..<1_000, recordingStartSample: 9_000)
      ])
    #expect(RecordingSessionKernel.trimmedTimeline(map, leadSamples: 4_000).isEmpty)
    #expect(RecordingSessionKernel.trimmedTimeline(map, leadSamples: 0) == map)
  }

  /// Distinct samples (a slow ramp on a voiced level), so a stretch mapped to the wrong place
  /// cannot match by accident.
  private static func voicedRamp(_ count: Int) -> [Float] {
    (0..<count).map { 0.2 + Float($0) * 0.000_001 }
  }

  @Test(
    "Phase 2 retry over a VAD-gapped take with a preserved tail: the map rebuilds the decoded audio from the recording and its sentences land where they were said"
  )
  func retryTimingMapsGapsAndTail() async throws {
    let sink = SinkLog()
    let ctx = context(
      sink: sink, preference: Preference([true]), receipt: Receipt(), behavior: .crashOnFinalize)
    let wrapper = try #require(ctx.sut as? KernelRecordingSession)
    // 12.5 s of voiced audio. VAD heard two passages and stopped 2 s before the capture did,
    // so the decode input is two filtered stretches plus the preserved 2 s tail.
    let capture = Self.voicedRamp(200_000)
    let text = "Hello there. Second one."
    ctx.engine.retryDecodeResult = .transcript(
      ASRResult(
        text: text, language: nil, duration: 10.3, processingTime: 0.1, backendType: .parakeet,
        wordTimings: [
          ASRWordTiming(word: "Hello", range: 0..<5, startMs: 100, endMs: 400),
          ASRWordTiming(word: "there.", range: 6..<12, startMs: 450, endMs: 900),
          ASRWordTiming(word: "Second", range: 13..<19, startMs: 5_300, endMs: 5_600),
          ASRWordTiming(word: "one.", range: 20..<24, startMs: 8_400, endMs: 8_600),
        ],
        wordTimingCoverage: ASRWordTimingCoverage(timed: 21, total: 21)))

    await wrapper.apply(.start)
    await wrapper.drainReadyWork()
    ctx.capture.deliverSamples(capture)
    ctx.vad.evidence = .voiced
    ctx.vad.segments = [
      SpeechSegment(startSample: 10_000, endSample: 90_000),
      SpeechSegment(startSample: 120_000, endSample: 166_400),
    ]
    await wrapper.drainReadyWork()
    await wrapper.apply(.stop)
    await wrapper.drainUntilConcluded()

    #expect(wrapper.testKernel.recordingOutcome == .completed)
    // A retry stamps fresh completion telemetry without tail fields, so the preserved tail is
    // proven by the third stretch of the map below, not by telemetry.
    let request = try #require(sink.requests.first)
    #expect(request.samples == capture, "the recording is the raw capture, untouched")
    #expect(request.asr.source == .phase2Retry)
    #expect(request.asr.input == .conditionedBatch)
    let timing = try #require(request.asr.timing)
    let decoded = try #require(ctx.engine.lastRetryDecodeInputSamples)
    #expect(
      timing.timeline == [
        DictationAudioTimelineSpan(decodeRange: 0..<83_200, recordingStartSample: 8_400),
        DictationAudioTimelineSpan(decodeRange: 83_200..<132_800, recordingStartSample: 118_400),
        DictationAudioTimelineSpan(decodeRange: 132_800..<164_800, recordingStartSample: 168_000),
      ])
    #expect(timing.timeline.last?.decodeRange.upperBound == decoded.count)
    try expectTimelineReproducesDecode(
      decode: decoded, recording: request.samples, timeline: timing.timeline)

    // The persisted sidecar for this take: one anchor per sentence on the recording's clock.
    // "Second one." starts after the VAD gap and ends inside the preserved tail.
    let sidecar = DictationTimingBuilder.timing(
      for: request.asr, recordingSampleCount: request.samples.count)
    #expect(sidecar.exactASRText == text)
    #expect(
      sidecar.anchors == [
        RecordingTiming.Anchor(utf16Start: 0, utf16End: 12, startSeconds: 0.625, endSeconds: 1.425),
        RecordingTiming.Anchor(utf16Start: 13, utf16End: 24, startSeconds: 7.5, endSeconds: 10.8),
      ])
  }

  @Test(
    "a timed lead-trim salvage carries the shifted map end to end, and its sentence lands after the cut lead"
  )
  func salvageCoordinates() async throws {
    let sink = SinkLog()
    let ctx = context(
      sink: sink, preference: Preference([true]), receipt: Receipt(),
      behavior: .emptyThenScripted(text: "Salvaged text.", emptyCalls: 1))
    let wrapper = try #require(ctx.sut as? KernelRecordingSession)
    // The measured degraded-lead shape (burst, near-dead window, recovered speech), with a
    // per-sample wobble so every stretch is distinguishable.
    func shape(_ count: Int, _ level: Float, from offset: Int) -> [Float] {
      (0..<count).map { level * (1 + 0.000_1 * Float((offset + $0) % 997)) }
    }
    let capture = shape(8_000, 0.3, from: 0) + shape(16_000, 0.002, from: 8_000)
      + shape(24_000, 0.25, from: 24_000)
    let segments = [SpeechSegment(startSample: 0, endSample: 48_000)]
    // The salvage decode returns real-shaped word timings on ITS input (the buffer without the
    // cut lead): "Salvaged text." heard from 100 ms to 600 ms into that input.
    let text = "Salvaged text."
    ctx.engine.finalizeWordTimings = [
      text: [
        ASRWordTiming(word: "Salvaged", range: 0..<8, startMs: 100, endMs: 350),
        ASRWordTiming(word: "text.", range: 9..<14, startMs: 400, endMs: 600),
      ]
    ]

    await wrapper.apply(.start)
    await wrapper.drainReadyWork()
    ctx.capture.deliverSamples(capture)
    ctx.vad.evidence = .voiced
    ctx.vad.segments = segments
    await wrapper.drainReadyWork()
    await wrapper.apply(.stop)
    await wrapper.drainUntilConcluded()

    #expect(wrapper.testKernel.deliveredTranscript == text)
    let request = try #require(sink.requests.first)
    #expect(request.asr.source == .leadSalvage)
    guard case .conditionedBatchTrimmed(let lead) = request.asr.input else {
      Issue.record("salvage input is \(request.asr.input)")
      return
    }
    #expect(lead > 0)
    let decoded = try #require(ctx.engine.lastFinalizeBatchSamples)
    let conditioned = CapturedAudioConditioner.condition(rawSamples: capture, vadSegments: segments)
    #expect(decoded == Array(conditioned.samples[lead...]))
    let shifted = RecordingSessionKernel.trimmedTimeline(conditioned.timeline, leadSamples: lead)
    #expect(shifted.first?.recordingStartSample == lead)

    // The evidence the kernel handed over is the salvage decode's own: its words, and the map
    // shifted by the cut lead, which rebuilds the salvage decode input from the recording.
    let timing = try #require(request.asr.timing, "a timed salvage must carry timing evidence")
    #expect(request.asr.wordTimingsAvailable)
    #expect(timing.words == ctx.engine.finalizeWordTimings?[text])
    #expect(timing.timeline == shifted)
    try expectTimelineReproducesDecode(
      decode: decoded, recording: request.samples, timeline: timing.timeline)

    // On the recording's clock the sentence starts `lead` samples later than the salvage
    // decode's own clock says: 100 ms into the trimmed input is `lead + 1,600` samples in.
    let sidecar = DictationTimingBuilder.timing(
      for: request.asr, recordingSampleCount: request.samples.count)
    #expect(
      sidecar.anchors == [
        RecordingTiming.Anchor(
          utf16Start: 0, utf16End: 14, startSeconds: Double(lead + 1_600) / 16_000,
          endSeconds: Double(lead + 9_600) / 16_000)
      ])
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
