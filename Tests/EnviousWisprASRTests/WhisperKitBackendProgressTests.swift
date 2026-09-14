import Foundation
import Testing

@testable import EnviousWisprASR

/// #2918 — the transcribing bar's number. WhisperKit's chunked file path decodes up to 16
/// windows in parallel and hands back each finished window's segments out of order, so the
/// fraction is the MAX segment end over the unpadded length, never the last value.
///
/// **When this fails, the Working card's transcribing bar jumps backwards or overshoots the
/// end of the file.** Product coverage.
@Suite(.tags(.productOutcome))
struct WhisperKitBackendProgressTests {

  @Test("the fraction is the max segment end over the length, clamped, and 0 with no segments")
  func fractionArithmetic() {
    #expect(WhisperKitBackend.fractionReached(segmentEnds: [12.0, 41.5, 29.9], totalSeconds: 100) == 0.415)
    #expect(WhisperKitBackend.fractionReached(segmentEnds: [100.4], totalSeconds: 100) == 1, "the padded tail")
    #expect(WhisperKitBackend.fractionReached(segmentEnds: [], totalSeconds: 100) == 0)
    #expect(WhisperKitBackend.fractionReached(segmentEnds: [5], totalSeconds: 0) == 0, "no length, no fraction")
    #expect(WhisperKitBackend.fractionReached(segmentEnds: [-1], totalSeconds: 100) == 0)
  }

  @Test("windows finishing out of order never move the reported fraction backwards")
  func monotoneAcrossWindows() {
    // Each callback carries ONE window's segments; the running max lives in the backend's
    // high-water box, which this pure function feeds. Modelled here as the max so far.
    var reported: [Double] = []
    var high = 0.0
    for ends in [[60.0], [30.0], [90.0], [0.5]] as [[Float]] {
      let fraction = WhisperKitBackend.fractionReached(segmentEnds: ends, totalSeconds: 120)
      if fraction > high {
        high = fraction
        reported.append(fraction)
      }
    }
    #expect(reported == [0.5, 0.75])
  }
}
