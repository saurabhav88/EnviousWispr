@preconcurrency import FluidAudio
import Testing

@testable import EnviousWisprAudio

@Suite("SilenceDetector boundary events")
struct SilenceDetectorBoundaryTests {
  @Test("FluidAudio speech events define segment boundaries")
  func streamEventsDefineSegmentBoundaries() async {
    let detector = SilenceDetector()

    await detector.applyStreamBoundary(
      VadStreamEvent(kind: .speechStart, sampleIndex: 4_096)
    )
    await detector.applyStreamBoundary(
      VadStreamEvent(kind: .speechEnd, sampleIndex: 20_480)
    )

    let segments = await detector.speechSegments
    #expect(segments.count == 1)
    #expect(segments.first?.startSample == 4_096)
    #expect(segments.first?.endSample == 20_480)
  }

  @Test("manual stop finalizes an open stream-event segment")
  func finalizeSegmentsClosesOpenBoundary() async {
    let detector = SilenceDetector()

    await detector.applyStreamBoundary(
      VadStreamEvent(kind: .speechStart, sampleIndex: 8_192)
    )
    await detector.finalizeSegments(totalSampleCount: 24_000)

    let segments = await detector.speechSegments
    #expect(segments.count == 1)
    #expect(segments.first?.startSample == 8_192)
    #expect(segments.first?.endSample == 24_000)
  }

  @Test("invalid speech end does not emit a malformed segment")
  func invalidSpeechEndDoesNotEmitSegment() async {
    let detector = SilenceDetector()

    await detector.applyStreamBoundary(
      VadStreamEvent(kind: .speechStart, sampleIndex: 12_288)
    )
    await detector.applyStreamBoundary(
      VadStreamEvent(kind: .speechEnd, sampleIndex: 12_288)
    )

    let segments = await detector.speechSegments
    #expect(segments.isEmpty)
  }
}
