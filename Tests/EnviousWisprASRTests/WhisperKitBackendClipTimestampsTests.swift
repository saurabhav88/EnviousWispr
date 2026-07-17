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
