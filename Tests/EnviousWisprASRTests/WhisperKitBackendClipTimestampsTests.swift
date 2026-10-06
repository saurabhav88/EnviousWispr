import EnviousWisprCore
import Foundation
import Testing
@preconcurrency import WhisperKit

@testable import EnviousWisprASR

@Suite("WhisperKitBackend clipTimestamps")
struct WhisperKitBackendClipTimestampsTests {
  @Test("clipTimestamps empty when no speech segments")
  func clipTimestamps_emptyWhenNoSpeechSegments() async {
    let backend = WhisperKitBackend(admittedModelFolder: { nil })
    let opts = await backend.makeDecodeOptions(
      from: TranscriptionOptions(speechSegments: []),
      sampleCount: 16_000
    )

    #expect(opts.clipTimestamps.isEmpty)
  }

  @Test("clipTimestamps pairs converted to seconds")
  func clipTimestamps_pairsConvertedToSeconds() async {
    let backend = WhisperKitBackend(admittedModelFolder: { nil })
    let sampleRate = Float(WhisperKit.sampleRate)
    let segments = [
      SpeechSegment(
        startSample: Int(WhisperKit.sampleRate), endSample: Int(WhisperKit.sampleRate) * 2),
      SpeechSegment(
        startSample: Int(WhisperKit.sampleRate) * 3, endSample: Int(WhisperKit.sampleRate) * 4),
    ]

    let opts = await backend.makeDecodeOptions(
      from: TranscriptionOptions(speechSegments: segments),
      sampleCount: Int(WhisperKit.sampleRate) * 5
    )

    #expect(
      opts.clipTimestamps == [
        Float(segments[0].startSample) / sampleRate,
        Float(segments[0].endSample) / sampleRate,
        Float(segments[1].startSample) / sampleRate,
        Float(segments[1].endSample) / sampleRate,
      ])
  }

  @Test("windowClipTime is still zero")
  func windowClipTime_isStillZero() async {
    let backend = WhisperKitBackend(admittedModelFolder: { nil })
    let opts = await backend.makeDecodeOptions(
      from: TranscriptionOptions(
        speechSegments: [SpeechSegment(startSample: 0, endSample: Int(WhisperKit.sampleRate))]
      ),
      sampleCount: Int(WhisperKit.sampleRate)
    )

    #expect(opts.windowClipTime == 0)
  }

  @Test("chunking strategy unchanged for 30s boundary")
  func chunkingStrategyUnchangedFor30sBoundary() async {
    let backend = WhisperKitBackend(admittedModelFolder: { nil })
    let thirtySeconds = Int(WhisperKit.sampleRate) * 30

    let atBoundary = await backend.makeDecodeOptions(
      from: .default,
      sampleCount: thirtySeconds
    )
    let aboveBoundary = await backend.makeDecodeOptions(
      from: .default,
      sampleCount: thirtySeconds + 1
    )

    // Disambiguate: `.none` alone resolves to Optional<ChunkingStrategy>.none (nil),
    // not ChunkingStrategy.none. The actual value is .some(ChunkingStrategy.none).
    #expect(atBoundary.chunkingStrategy == ChunkingStrategy.none)
    #expect(aboveBoundary.chunkingStrategy == ChunkingStrategy.vad)
  }

  @Test("zero-width speech segment produces clip pair")
  func clipTimestamps_zeroWidthSegmentDoesNotCrash() async {
    let backend = WhisperKitBackend(admittedModelFolder: { nil })
    let segment = SpeechSegment(
      startSample: Int(WhisperKit.sampleRate),
      endSample: Int(WhisperKit.sampleRate)
    )

    let opts = await backend.makeDecodeOptions(
      from: TranscriptionOptions(speechSegments: [segment]),
      sampleCount: Int(WhisperKit.sampleRate) * 2
    )

    #expect(opts.clipTimestamps == [1.0, 1.0])
  }

  /// #2190: a clip must never end at the audio's exact duration (the pinned `whisperkit-cli`
  /// crashes on that shape). Two-way control: a clip that ends well before the end is untouched,
  /// so the headroom is not a blanket shortening.
  @Test("a clip ending at the exact duration ends one sample earlier (#2190)")
  func clipTimestamps_endAtDurationGetsOneSampleOfHeadroom() async {
    let backend = WhisperKitBackend(admittedModelFolder: { nil })
    let rate = Int(WhisperKit.sampleRate)
    let total = rate * 3
    let opts = await backend.makeDecodeOptions(
      from: TranscriptionOptions(
        speechSegments: [
          SpeechSegment(startSample: 0, endSample: rate),
          SpeechSegment(startSample: rate * 2, endSample: total),
        ]),
      sampleCount: total
    )

    let duration = Float(total) / Float(WhisperKit.sampleRate)
    #expect(opts.clipTimestamps.count == 4)
    #expect(opts.clipTimestamps[1] == 1.0, "a clip well before the end must be unchanged")
    #expect(opts.clipTimestamps[3] < duration, "the last clip still ends at the exact duration")
    #expect(opts.clipTimestamps[3] == Float(total - 1) / Float(WhisperKit.sampleRate))
  }

  @Test("a segment past the end is clamped, then given the same headroom (#2190)")
  func clipTimestamps_overshootEndsOneSampleBeforeDuration() async {
    let backend = WhisperKitBackend(admittedModelFolder: { nil })
    let rate = Int(WhisperKit.sampleRate)
    let opts = await backend.makeDecodeOptions(
      from: TranscriptionOptions(
        speechSegments: [SpeechSegment(startSample: rate, endSample: rate * 10)]),
      sampleCount: rate * 2
    )

    #expect(opts.clipTimestamps == [1.0, Float(rate * 2 - 1) / Float(WhisperKit.sampleRate)])
  }

  @Test("the headroom cannot underflow on an empty or one-sample capture (#2190)")
  func clipTimestamps_headroomCannotUnderflow() async {
    let backend = WhisperKitBackend(admittedModelFolder: { nil })
    for count in [0, 1] {
      let opts = await backend.makeDecodeOptions(
        from: TranscriptionOptions(
          speechSegments: [SpeechSegment(startSample: 0, endSample: count)]),
        sampleCount: count
      )
      #expect(
        opts.clipTimestamps == [0, 0],
        "sampleCount \(count) must give the empty clip [0, 0], never a negative or reversed one")
    }
  }

  /// Float seconds lose the sample: at an hour of audio one Float step is about four samples, so
  /// `(count - 1) / 16000` and `count / 16000` can be the same number. Dictation is capped at 60
  /// minutes (#1060), so this size is real.
  @Test("the headroom survives Float rounding on a very long capture (#2190)")
  func clipTimestamps_headroomSurvivesFloatRoundingOnALongCapture() async {
    let backend = WhisperKitBackend(admittedModelFolder: { nil })
    let rate = Int(WhisperKit.sampleRate)
    for seconds in [2048, 3600] {
      let total = rate * seconds
      let opts = await backend.makeDecodeOptions(
        from: TranscriptionOptions(
          speechSegments: [SpeechSegment(startSample: rate * 60, endSample: total)]),
        sampleCount: total
      )

      let duration = Float(total) / Float(WhisperKit.sampleRate)
      #expect(opts.clipTimestamps.count == 2)
      #expect(opts.clipTimestamps[0] == 60.0)
      #expect(opts.clipTimestamps[1] < duration, "\(seconds) s: the clip still ends at the duration")
    }
  }

  @Test("empty speechSegments produces same options as default")
  func emptySpeechSegments_producesSameOptionsAsToday() async {
    let backend = WhisperKitBackend(admittedModelFolder: { nil })
    let defaultOptions = await backend.makeDecodeOptions(
      from: .default,
      sampleCount: 16_000
    )
    let explicitEmptyOptions = await backend.makeDecodeOptions(
      from: TranscriptionOptions(speechSegments: []),
      sampleCount: 16_000
    )

    #expect(defaultOptions.clipTimestamps == explicitEmptyOptions.clipTimestamps)
    #expect(defaultOptions.windowClipTime == explicitEmptyOptions.windowClipTime)
    #expect(defaultOptions.chunkingStrategy == explicitEmptyOptions.chunkingStrategy)
    #expect(defaultOptions.language == explicitEmptyOptions.language)
    #expect(defaultOptions.wordTimestamps == explicitEmptyOptions.wordTimestamps)
    #expect(defaultOptions.suppressBlank == explicitEmptyOptions.suppressBlank)
    #expect(defaultOptions.usePrefillPrompt == explicitEmptyOptions.usePrefillPrompt)
  }
}
