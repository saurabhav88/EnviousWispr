import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAudio

// MARK: - #1434 HAL format stabilization (pure settle loop)
//
// `HALDeviceInputSource.settleNativeRate` is the separated core of the real
// `waitForFormatStabilization` (which replaced a stub asserting the claim
// Apple QA1777 refutes). Tests inject a scripted rate reader + no-op sleep so
// assertions gate on returned values, never the wall clock (`test-timing`).

@MainActor
@Suite("HALDeviceInputSource — format stabilization settle loop (#1434)")
struct HALFormatStabilizationTests {

  /// Scripted reader: returns `readings[n]` for the n-th call, repeating the
  /// last value once the script is exhausted.
  private func reader(_ readings: [Double?]) -> () -> Double? {
    var index = 0
    return {
      defer { index += 1 }
      return index < readings.count ? readings[index] : readings.last ?? nil
    }
  }

  private func settle(
    prepared: Double, readings: [Double?],
    maxWait: TimeInterval = 1.5, pollInterval: TimeInterval = 0.2
  ) async -> HALDeviceInputSource.RateSettleOutcome {
    await HALDeviceInputSource.settleNativeRate(
      preparedRate: prepared, maxWait: maxWait, pollInterval: pollInterval,
      readRate: reader(readings), sleep: { _ in })
  }

  @Test("stable rate matching the prepared rate settles true on the fast path")
  func stableMatchFastPath() async {
    let outcome = await settle(prepared: 24000, readings: [24000, 24000])
    #expect(outcome.matchesPrepared)
    #expect(outcome.settledRate == 24000)
    #expect(outcome.polls == 0)
  }

  @Test("transient wrong read then settle (Apple forum 770232 shape) returns true")
  func transientWrongReadThenSettle() async {
    // First read 48000, correcting to 24000 — the documented AirPods pattern.
    let outcome = await settle(prepared: 24000, readings: [48000, 24000, 24000])
    #expect(outcome.matchesPrepared)
    #expect(outcome.settledRate == 24000)
    #expect(outcome.polls >= 1)
  }

  @Test("settled-but-DIVERGENT rate returns false — routes into the rebuild seam")
  func settledDivergentIsFalse() async {
    let outcome = await settle(prepared: 24000, readings: [16000, 16000])
    #expect(!outcome.matchesPrepared)
    #expect(outcome.settledRate == 16000)
  }

  @Test("never-settling rate exhausts the poll budget and returns false")
  func neverSettlesIsFalse() async {
    // Alternating reads never agree twice in a row.
    var flip = false
    let outcome = await HALDeviceInputSource.settleNativeRate(
      preparedRate: 24000, maxWait: 1.5, pollInterval: 0.2,
      readRate: {
        flip.toggle()
        return flip ? 24000 : 16000
      },
      sleep: { _ in })
    #expect(!outcome.matchesPrepared)
    #expect(outcome.settledRate == nil)
    // Poll budget = maxWait / pollInterval — bounded, not wall-clock.
    #expect(outcome.polls == 7)
  }

  @Test("nil reads (property query failing) never count as settled")
  func nilReadsNeverSettle() async {
    let outcome = await settle(prepared: 24000, readings: [nil, nil, nil])
    #expect(!outcome.matchesPrepared)
    #expect(outcome.settledRate == nil)
  }

  @Test("instance wrapper with no bound device returns true (nothing to stabilize)")
  func unpreparedInstanceReturnsTrue() async {
    let source = HALDeviceInputSource()
    let stabilized = await source.waitForFormatStabilization(maxWait: 1.5, pollInterval: 0.2)
    #expect(stabilized)
  }
}

// MARK: - #1434 CaptureStopMetadata transport round-trip

@Suite("CaptureStopMetadata — XPC transport round-trip (#1434)")
struct CaptureStopMetadataTransportTests {

  @Test("encodes and decodes losslessly (the XPC stop-reply blob)")
  func codableRoundTrip() throws {
    let original = CaptureStopMetadata(
      nativeRateHz: 24000, ringDropCount: 3, converterErrorCount: 1,
      zeroOutputCount: 2, rateDivergenceDetected: true)
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(CaptureStopMetadata.self, from: data)
    #expect(decoded == original)
  }

  @Test("nil rate survives the round trip; CaptureResult defaults keep metadata nil")
  func nilRateAndDefaults() throws {
    let original = CaptureStopMetadata(nativeRateHz: nil)
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(CaptureStopMetadata.self, from: data)
    #expect(decoded == original)
    #expect(decoded.nativeRateHz == nil)
    // Every pre-#1434 constructor compiles unchanged and yields nil metadata.
    #expect(CaptureResult(samples: []).metadata == nil)
    #expect(CaptureResult(samples: [], vadSegments: []).metadata == nil)
  }
}
