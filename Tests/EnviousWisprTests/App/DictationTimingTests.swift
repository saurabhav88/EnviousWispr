import EnviousWisprASR
import EnviousWisprCore
import EnviousWisprStorage
@preconcurrency import FluidAudio
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprPipeline

/// #3147 §3.2: the sentence times a saved dictation shows. When these fail, a History paragraph
/// time seeks to the wrong passage, plays padding that was never recorded, or shows a time the
/// speech engine never gave (Whisper, a streaming win, a word it could not time).
@Suite("Dictation sentence timings (#3147)", .tags(.productOutcome))
struct DictationTimingTests {

  private static let rate = 16_000

  /// Decode input: 0..<16,000 is recording 8,000..<24,000; after a VAD gap, 16,000..<48,000 is
  /// recording 64,000..<96,000. The recording is 100,000 samples (6.25 s).
  private static let gapped = [
    DictationAudioTimelineSpan(decodeRange: 0..<16_000, recordingStartSample: 8_000),
    DictationAudioTimelineSpan(decodeRange: 16_000..<48_000, recordingStartSample: 64_000),
  ]

  private static func word(_ text: String, _ range: Range<Int>, _ start: Int?, _ end: Int?)
    -> ASRWordTiming
  {
    ASRWordTiming(word: text, range: range, startMs: start, endMs: end)
  }

  private static func evidence(
    _ text: String, words: [ASRWordTiming], timeline: [DictationAudioTimelineSpan] = gapped,
    backend: ASRBackendType = .parakeet, source: DictationASREvidence.Source = .batch,
    input: DictationASREvidence.DecodeInput = .conditionedBatch
  ) -> DictationASREvidence {
    DictationASREvidence(
      text: text, backend: backend, source: source, input: input, wordTimingsAvailable: true,
      timing: DictationTimingEvidence(words: words, timeline: timeline, sampleRate: rate))
  }

  /// "Hi there. Bye now!" with every word timed; "Bye" is said after the VAD gap.
  private static let twoSentences = evidence(
    "Hi there. Bye now!",
    words: [
      word("Hi", 0..<2, 100, 300), word("there.", 3..<9, 350, 800),
      word("Bye", 10..<13, 1_200, 1_500), word("now!", 14..<18, 1_600, 2_000),
    ])

  private static func anchors(_ asr: DictationASREvidence, recording: Int = 100_000)
    -> [RecordingTiming.Anchor]
  {
    DictationTimingBuilder.timing(for: asr, recordingSampleCount: recording).anchors
  }

  @Test("each sentence starts and ends where its first and last words were heard in the recording")
  func sentencesLandOnTheRecording() {
    let timing = DictationTimingBuilder.timing(
      for: Self.twoSentences, recordingSampleCount: 100_000)

    #expect(timing.exactASRText == "Hi there. Bye now!")
    #expect(timing.textVersion == DictationTimingBuilder.textVersion(of: "Hi there. Bye now!"))
    // "Hi" at 100 ms = decode 1,600 = recording 9,600; "there." ends at decode 12,800 =
    // recording 20,800. "Bye" at decode 19,200 sits past the gap: recording 67,200; "now!" ends
    // at decode 32,000 = recording 80,000.
    #expect(
      timing.anchors == [
        RecordingTiming.Anchor(utf16Start: 0, utf16End: 9, startSeconds: 0.6, endSeconds: 1.3),
        RecordingTiming.Anchor(utf16Start: 10, utf16End: 18, startSeconds: 4.2, endSeconds: 5.0),
      ])
  }

  @Test("Whisper, a streaming win and raw-fed decodes stay untimed but keep their text identity")
  func unsupportedDecodesStayUntimed() throws {
    let words = try #require(Self.twoSentences.timing).words
    let text = Self.twoSentences.text
    let untimed: [DictationASREvidence] = [
      Self.evidence(text, words: words, backend: .whisper),
      Self.evidence(text, words: words, source: .streaming, input: .rawCapture),
      Self.evidence(text, words: words, input: .paddedRawCapture),
      DictationASREvidence(
        text: text, backend: .parakeet, source: .batch, input: .conditionedBatch,
        wordTimingsAvailable: false),
    ]
    for asr in untimed {
      let timing = DictationTimingBuilder.timing(for: asr, recordingSampleCount: 100_000)
      #expect(timing.anchors.isEmpty, "\(asr.backend) \(asr.source) \(asr.input)")
      #expect(timing.exactASRText == text)
      #expect(timing.textVersion == DictationTimingBuilder.textVersion(of: text))
    }
    // Every supported batch source does time the same evidence.
    for source: DictationASREvidence.Source in [.batch, .batchRescue, .leadSalvage, .phase2Retry] {
      #expect(Self.anchors(Self.evidence(text, words: words, source: source)).count == 2)
    }
  }

  @Test("a sentence whose first or last word has no time gets no anchor; its neighbour keeps one")
  func untimedEdgeWordsLeaveTheSentenceUntimed() {
    let firstUntimed = Self.evidence(
      "Hi there. Bye now!",
      words: [
        Self.word("Hi", 0..<2, nil, nil), Self.word("there.", 3..<9, 350, 800),
        Self.word("Bye", 10..<13, 1_200, 1_500), Self.word("now!", 14..<18, 1_600, 2_000),
      ])
    #expect(Self.anchors(firstUntimed).map(\.utf16Start) == [10], "never borrow 'there.' as start")

    let lastUntimed = Self.evidence(
      "Hi there. Bye now!",
      words: [
        Self.word("Hi", 0..<2, 100, 300), Self.word("there.", 3..<9, 350, 800),
        Self.word("Bye", 10..<13, 1_200, 1_500), Self.word("now!", 14..<18, nil, nil),
      ])
    #expect(Self.anchors(lastUntimed).map(\.utf16Start) == [0], "never borrow 'Bye' as end")
  }

  @Test("a time in decode padding never maps onto the recording")
  func paddingIsNeverAnchored() {
    // A short take: 10,000 real samples, padded to 16,000 for the engine. "yes." ends at
    // 700 ms = decode 11,200, inside the padding.
    let short = [DictationAudioTimelineSpan(decodeRange: 0..<10_000, recordingStartSample: 0)]
    let endsInPadding = Self.evidence(
      "Yes.", words: [Self.word("Yes.", 0..<4, 100, 700)], timeline: short)
    #expect(Self.anchors(endsInPadding, recording: 10_000).isEmpty)

    // Ends on the last real sample: 625 ms = decode 10,000 (exclusive end) is timed.
    let endsOnAudio = Self.evidence(
      "Yes.", words: [Self.word("Yes.", 0..<4, 100, 625)], timeline: short)
    #expect(
      Self.anchors(endsOnAudio, recording: 10_000) == [
        RecordingTiming.Anchor(utf16Start: 0, utf16End: 4, startSeconds: 0.1, endSeconds: 0.625)
      ])

    // Starts at the first padding sample: no anchor.
    let startsInPadding = Self.evidence(
      "Yes.", words: [Self.word("Yes.", 0..<4, 625, 700)], timeline: short)
    #expect(Self.anchors(startsInPadding, recording: 10_000).isEmpty)
  }

  @Test("a map that leaves the recording or runs out of order gives no anchors at all")
  func invalidMapsGiveNoAnchors() throws {
    let words = try #require(Self.twoSentences.timing).words
    let text = Self.twoSentences.text
    let invalid: [[DictationAudioTimelineSpan]] = [
      [],  // nothing mapped
      // Beyond the 100,000-sample recording.
      [DictationAudioTimelineSpan(decodeRange: 0..<48_000, recordingStartSample: 60_000)],
      // Decode stretches overlap.
      [
        DictationAudioTimelineSpan(decodeRange: 0..<20_000, recordingStartSample: 0),
        DictationAudioTimelineSpan(decodeRange: 10_000..<48_000, recordingStartSample: 30_000),
      ],
      // Recording stretches run backwards.
      [
        DictationAudioTimelineSpan(decodeRange: 0..<16_000, recordingStartSample: 50_000),
        DictationAudioTimelineSpan(decodeRange: 16_000..<48_000, recordingStartSample: 0),
      ],
      // An empty stretch.
      [DictationAudioTimelineSpan(decodeRange: 5..<5, recordingStartSample: 0)],
    ]
    for timeline in invalid {
      #expect(Self.anchors(Self.evidence(text, words: words, timeline: timeline)).isEmpty)
    }
    #expect(Self.anchors(Self.twoSentences, recording: 0).isEmpty)
  }

  @Test("word timings that are not the delivered text give no anchors at all")
  func mismatchedWordsGiveNoAnchors() {
    let text = "Hi there. Bye now!"
    let mismatches: [[ASRWordTiming]] = [
      // Wrong word at the range.
      [Self.word("Ho", 0..<2, 100, 300), Self.word("there.", 3..<9, 350, 800)],
      // A range past the end of the text.
      [Self.word("Hi", 0..<2, 100, 300), Self.word("now!", 14..<30, 1_600, 2_000)],
      // Out of order.
      [Self.word("there.", 3..<9, 350, 800), Self.word("Hi", 0..<2, 100, 300)],
      [],
    ]
    for words in mismatches {
      #expect(Self.anchors(Self.evidence(text, words: words)).isEmpty)
    }
  }

  @Test("a sentence that would start before the previous one ended stays untimed")
  func overlappingSentencesStayUntimed() {
    let overlapping = Self.evidence(
      "Hi there. Bye now!",
      words: [
        Self.word("Hi", 0..<2, 100, 300), Self.word("there.", 3..<9, 350, 1_400),
        Self.word("Bye", 10..<13, 1_200, 1_500), Self.word("now!", 14..<18, 1_600, 2_000),
      ])
    #expect(Self.anchors(overlapping).map(\.utf16Start) == [0])
  }

  @Test(
    "sentences split after closing quotes and every final mark, on the real word mapper's output")
  func sentenceSplitsOnMapperOutput() {
    let text = "He said \u{201C}stop.\u{201D} Why? Fine\u{2026} Wait (really!) ok"
    let engine: [(word: String, startMs: Int?, endMs: Int?)] = [
      ("He", 0, 100), ("said", 120, 300), ("\u{201C}stop.\u{201D}", 320, 600),
      ("Why?", 700, 900), ("Fine\u{2026}", 1_000, 1_300), ("Wait", 1_400, 1_600),
      ("(really!)", 1_650, 1_900), ("ok", 2_000, 2_200),
    ]
    let mapped = WordTimingRangeMapper.map(text: text, audioDurationMs: 3_000, words: engine)
    let sentences = DictationTimingBuilder.sentences(of: mapped.words).map {
      $0.map(\.word).joined(separator: " ")
    }
    #expect(
      sentences == [
        "He said \u{201C}stop.\u{201D}", "Why?", "Fine\u{2026}", "Wait (really!)", "ok",
      ])

    let identity = [DictationAudioTimelineSpan(decodeRange: 0..<48_000, recordingStartSample: 0)]
    let asr = Self.evidence(text, words: mapped.words, timeline: identity)
    let anchors = Self.anchors(asr, recording: 48_000)
    #expect(anchors.count == 5, "every sentence is timed by the engine's own words")
    let utf16 = Array(text.utf16)
    let anchoredText = anchors.map {
      String(decoding: utf16[$0.utf16Start..<$0.utf16End], as: UTF16.self)
    }
    #expect(anchoredText == sentences)
    #expect(anchors.first?.startSeconds == 0)
    #expect(anchors.last?.endSeconds == 2.2)
  }

  // MARK: - Real boundary: the shipped engine's own word times

  /// A shipped Parakeet model installed in the directory the app installs it into: Ultra
  /// (the current shipped model) first, else v3.
  static var installedParakeet: ParakeetModel? {
    [ParakeetModel.ultra, .v3].first { model in
      AsrModels.modelsExist(
        at: ParakeetInstallLocation.directory(
          for: model, dataDirectory: StorageRoot.live.dataDirectory),
        version: model == .ultra ? .ultra : .v3)
    }
  }

  @Test(
    "the shipped engine's word times, through the real conditioner, place the sentence where it was said",
    .enabled(if: DictationTimingTests.installedParakeet != nil),
    .tags(.realBoundary), .realBoundaryRun
  )
  func shippedEngineSentenceLandsOnTheRecording() async throws {
    // A committed spoken clip, placed 2 s into a recording of silence. VAD heard only the clip,
    // so the conditioner cuts the silence and the engine's times start near the clip, not 2 s in.
    let clipURL = URL(filePath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appending(path: "scripts/freeze-suite/clips/normal-speech.wav")
    let clip = try await AudioFileDecoder.decode(url: clipURL).samples
    let lead = 32_000
    let recording = [Float](repeating: 0, count: lead) + clip + [Float](repeating: 0, count: 8_000)
    let conditioned = CapturedAudioConditioner.condition(
      rawSamples: recording,
      vadSegments: [SpeechSegment(startSample: lead, endSample: lead + clip.count)])
    #expect(conditioned.conditioningReason == "filtered")

    let model = try #require(Self.installedParakeet)
    let backend = ParakeetBackend()
    let result: EnviousWisprCore.ASRResult
    do {
      try await backend.prepare(
        selection: ParakeetModelSelection(
          model: model, revision: nil,
          directory: ParakeetInstallLocation.directory(
            for: model, dataDirectory: StorageRoot.live.dataDirectory),
          cacheOnly: true, displayBytes: ParakeetModel.v3ShippedBytes, repairable: false,
          generation: 1),
        progressCallback: nil)
      result = try await backend.transcribe(audioSamples: conditioned.samples, options: .default)
      await backend.unload()
    } catch {
      await backend.unload()
      throw error
    }

    let asr = RecordingSessionKernel.evidence(
      result, source: .batch, input: .conditionedBatch, timeline: conditioned.timeline)
    let timing = DictationTimingBuilder.timing(for: asr, recordingSampleCount: recording.count)
    #expect(timing.exactASRText == result.text)
    let first = try #require(timing.anchors.first, "no anchor from: \(result.text)")
    let last = try #require(timing.anchors.last)
    // The decode input starts at the VAD segment minus its 0.1 s padding (recording sample
    // 30,400), so that is the earliest place an engine time can land.
    let decodeStart = Double(lead - AudioConstants.speechPaddingSamples) / Double(Self.rate)
    let clipEnd = Double(lead + clip.count) / Double(Self.rate)
    // On the recording's clock the speech is inside the clip: never in the leading silence the
    // decode never saw, never past the clip's end.
    #expect(
      first.startSeconds >= decodeStart,
      "starts at \(first.startSeconds)s, decode input begins at \(decodeStart)s")
    #expect(first.startSeconds < clipEnd)
    #expect(last.endSeconds <= clipEnd + 0.1, "ends at \(last.endSeconds)s, clip ends \(clipEnd)s")
    #expect(first.utf16Start >= 0)
    #expect(last.utf16End <= result.text.utf16.count)
  }
}
