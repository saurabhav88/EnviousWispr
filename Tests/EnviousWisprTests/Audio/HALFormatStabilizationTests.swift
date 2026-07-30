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

  // MARK: - #1445 validity guard (shared rate clause with isUsableFormat)

  @Test("isUsableRate rejects nil, zero, negative, and NaN; accepts positive (#1445)")
  func isUsableRatePredicate() {
    #expect(!HALDeviceInputSource.isUsableRate(nil))
    #expect(!HALDeviceInputSource.isUsableRate(0))
    #expect(!HALDeviceInputSource.isUsableRate(-1))
    #expect(!HALDeviceInputSource.isUsableRate(Double.nan))
    #expect(HALDeviceInputSource.isUsableRate(24000))
  }

  @Test("two agreeing 0.0 reads do NOT fast-settle; it settles on the later valid rate (#1445)")
  func invalidZeroTwiceThenValidSettles() async {
    // Before the guard, two agreeing 0.0 reads settled at polls==0 with an
    // unusable settledRate. Now they fall through until a usable rate agrees.
    let outcome = await settle(prepared: 24000, readings: [0.0, 0.0, 24000, 24000])
    #expect(outcome.matchesPrepared)
    #expect(outcome.settledRate == 24000)
    #expect(outcome.polls >= 1)  // proves it did NOT fast-exit on the zeros
  }

  @Test("a device stuck at 0.0 never settles — invalid reads are not stable (#1445)")
  func invalidZeroForeverIsUnstable() async {
    let outcome = await settle(prepared: 24000, readings: [0.0, 0.0])
    #expect(!outcome.matchesPrepared)
    #expect(outcome.settledRate == nil)
  }

  @Test("no bound device short-circuits true WITHOUT reading the device rate (#1445)")
  func unpreparedDoesNotReadDeviceRate() async {
    let source = HALDeviceInputSource()
    var readerCalls = 0
    source.nativeRateReader = { _ in
      readerCalls += 1
      return 24000
    }
    let stabilized = await source.waitForFormatStabilization(maxWait: 1.5, pollInterval: 0.2)
    #expect(stabilized)
    #expect(readerCalls == 0)  // boundDeviceID/renderContext nil → short-circuit before any read
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

  @Test("#1523: a populated channel count survives the XPC round trip")
  func channelCountRoundTrip() throws {
    let original = CaptureStopMetadata(
      nativeRateHz: 48000, ringDropCount: 0, converterErrorCount: 0,
      zeroOutputCount: 0, rateDivergenceDetected: false, nativeChannelCount: 4)
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(CaptureStopMetadata.self, from: data)
    #expect(decoded == original)
    #expect(decoded.nativeChannelCount == 4)
  }

  @Test("#1523: a pre-field JSON blob (no channel key) decodes to a nil count")
  func preFieldBlobDecodesToNilChannelCount() throws {
    // A stop-reply blob encoded before #1523 shipped — no `nativeChannelCount`
    // key. The optional must decode to nil (forward-compatible XPC boundary).
    let preFieldJSON = """
      {"nativeRateHz":24000,"ringDropCount":1,"converterErrorCount":0,\
      "zeroOutputCount":0,"rateDivergenceDetected":false}
      """
    let data = Data(preFieldJSON.utf8)
    let decoded = try JSONDecoder().decode(CaptureStopMetadata.self, from: data)
    #expect(decoded.nativeChannelCount == nil)
    #expect(decoded.nativeRateHz == 24000)
    // #1788: the same blob predates the two gap counters, which are NOT optional.
    // Absent-means-zero keeps the boundary decoding instead of throwing.
    #expect(decoded.renderFailureCount == 0)
    #expect(decoded.oversizedSliceCount == 0)
    #expect(decoded.preRollGapCount == 0)
    #expect(decoded.inputTimelineGapCount == 1)  // the one ring drop above
  }

  @Test("#1788: the new gap counters survive the round trip")
  func gapCountersRoundTrip() throws {
    let original = CaptureStopMetadata(
      nativeRateHz: 48000, renderFailureCount: 2, oversizedSliceCount: 5,
      preRollGapCount: 7)
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(CaptureStopMetadata.self, from: data)
    #expect(decoded == original)
    #expect(decoded.renderFailureCount == 2)
    #expect(decoded.oversizedSliceCount == 5)
    #expect(decoded.preRollGapCount == 7)
  }
}

// MARK: - #1788 input-timeline gap enumeration

/// The wake instrument reads a sample INDEX as an elapsed time, which holds only
/// while the stream lost nothing. `inputTimelineGapCount` is the single owner of
/// "did it lose anything", so these tests pin every edge it must count — and the
/// one it must not. Cloud review found a fresh missing edge in three consecutive
/// rounds; the point of a freeze test here is that a fourth edge added without a
/// line in the sum fails loudly instead of silently under-reporting.
@Suite("CaptureStopMetadata — input-timeline gap enumeration (#1788)")
struct CaptureStopMetadataGapTests {

  @Test("a clean session reports zero gaps, so a wake is exact")
  func cleanSessionHasNoGaps() {
    let clean = CaptureStopMetadata(nativeRateHz: 24000)
    #expect(clean.inputTimelineGapCount == 0)
  }

  @Test("each lossy edge contributes exactly one gap")
  func everyLossyEdgeCounts() {
    #expect(
      CaptureStopMetadata(nativeRateHz: nil, ringDropCount: 1)
        .inputTimelineGapCount == 1)
    #expect(
      CaptureStopMetadata(nativeRateHz: nil, converterErrorCount: 1)
        .inputTimelineGapCount == 1)
    #expect(
      CaptureStopMetadata(nativeRateHz: nil, renderFailureCount: 1)
        .inputTimelineGapCount == 1)
    #expect(
      CaptureStopMetadata(nativeRateHz: nil, oversizedSliceCount: 1)
        .inputTimelineGapCount == 1)
  }

  @Test("a zero-frame converter output is NOT a gap — the input is emitted later")
  func zeroConverterOutputIsNotAGap() {
    // Cloud review r3 named this as a third loss source. It is not one: a priming
    // call consumes its input and emits it on the following call, so the output
    // timeline stays continuous. Counting it would report a floor on every
    // session, since priming legitimately yields one.
    let primed = CaptureStopMetadata(nativeRateHz: 24000, zeroOutputCount: 1)
    #expect(primed.inputTimelineGapCount == 0)
  }

  @Test("gaps sum across edges rather than saturating at one")
  func gapsSumAcrossEdges() {
    let messy = CaptureStopMetadata(
      nativeRateHz: 16000, ringDropCount: 4, converterErrorCount: 3,
      zeroOutputCount: 9, renderFailureCount: 2, oversizedSliceCount: 1)
    #expect(messy.inputTimelineGapCount == 10)  // 4+3+2+1, zeroOutput excluded
  }

  @Test("a gap carried in from idle pre-roll still counts (r4: the WINDOW)")
  func preRollGapIsInsideTheWakeWindow() {
    // The four session counters are reset before the retained pre-roll is
    // drained, and a measured wake begins inside that pre-roll. If the carry-in
    // were excluded, every one of those gaps would report as `exact` — the
    // instrument confidently wrong in exactly the window it measures. Cloud
    // review found this AFTER three rounds of edge-hunting, so the window is
    // frozen here separately from the edge list.
    let carried = CaptureStopMetadata(nativeRateHz: 24000, preRollGapCount: 2)
    #expect(carried.inputTimelineGapCount == 2)
    #expect(carried.ringDropCount == 0)  // not folded into a session counter
    #expect(carried.converterErrorCount == 0)
  }

  @Test("pre-roll carry-in adds to session gaps rather than replacing them")
  func preRollGapAddsToSessionGaps() {
    let both = CaptureStopMetadata(
      nativeRateHz: 24000, ringDropCount: 1, preRollGapCount: 3)
    #expect(both.inputTimelineGapCount == 4)
  }

  @Test("the catch-all lost-chunk count is a gap too (r7)")
  func lostChunkCountsAsAGap() {
    // r7 found TWO more silent exits on the pop->route path: buffer allocation
    // failure under memory pressure, and an unreadable converted buffer. Rather
    // than add a counter per cause — the list had already reopened in r3 and r5 —
    // `ForwardOutcome` now forces every exit to declare loss and this one counter
    // catches all of them, including exits not yet written.
    let lost = CaptureStopMetadata(nativeRateHz: 24000, lostChunkCount: 2)
    #expect(lost.inputTimelineGapCount == 2)
    #expect(lost.ringDropCount == 0)
    #expect(lost.converterErrorCount == 0)
  }
}
