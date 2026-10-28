import Foundation
import Testing

@testable import EnviousWisprCore

// MARK: - RawAudioDeadAirMeasurementTests (#1845)
//
// `measure` became the single implementation of the #964 gate and `isDeadAir`
// became a projection of it. Two obligations follow, and they are different:
//
//  1. EQUIVALENCE. `measure(...).isDeadAir` must decide exactly what the
//     pre-#1845 `isDeadAir` decided, on every shape the floor was tuned
//     against. A verdict change here is a heart-path routing change wearing a
//     telemetry PR's clothes.
//  2. SHORT-CIRCUIT FIDELITY. A `nil` RMS must mean "not computed", never
//     "computed as zero". #1845 exists because a fabricated zero is
//     indistinguishable from a digitally dead channel, and that trap is one
//     layer down here too.

@Suite("RawAudioDeadAirClassifier.measure (#1845)")
struct RawAudioDeadAirMeasurementTests {

  private func peak(_ samples: [Float]) -> Float {
    samples.reduce(Float(0)) { max($0, abs($1)) }
  }

  // MARK: Equivalence with the shipped verdict

  /// The shapes the #964 floor was tuned against, each asserted to give the
  /// SAME verdict through both entry points. Parameterized so a future shape is
  /// one row rather than a copied test.
  @Test(
    "measure and isDeadAir agree on every tuned shape",
    arguments: [
      // (label, samples, expectedDeadAir)
      ("uniform sub-floor", [Float](repeating: 0.001, count: 16_000), true),
      ("just below whole-buffer RMS", [Float](repeating: 0.0011, count: 16_000), true),
      ("just above whole-buffer RMS", [Float](repeating: 0.0013, count: 16_000), false),
      ("short buffer sub-floor", [Float](repeating: 0.001, count: 320), true),
      ("short buffer above window RMS", [Float](repeating: 0.0025, count: 320), false),
      ("empty buffer", [Float](), true),
    ] as [(String, [Float], Bool)]
  )
  func measureAgreesWithIsDeadAir(label: String, samples: [Float], expectedDeadAir: Bool) {
    let p = peak(samples)
    let measured = RawAudioDeadAirClassifier.measure(samples, peak: p)
    let projected = RawAudioDeadAirClassifier.isDeadAir(samples, peak: p)

    #expect(measured.isDeadAir == expectedDeadAir, "\(label): measure verdict")
    #expect(projected == expectedDeadAir, "\(label): isDeadAir verdict")
    #expect(measured.isDeadAir == projected, "\(label): the two entry points diverged")
  }

  /// A loud window buried in an otherwise silent buffer is the case the tiled
  /// window loop exists for. Whole-buffer RMS stays under its floor while the
  /// loudest window does not, so the verdict must be "not dead air" and the
  /// reported `maxWindowRMS` must exceed the reported `wholeBufferRMS`.
  @Test("a buried loud window is not dead air and reports the higher window value")
  func buriedLoudWindowIsNotDeadAir() {
    var samples = [Float](repeating: 0.0002, count: 16_000)
    for i in 3_200..<3_840 { samples[i] = 0.004 }

    let measured = RawAudioDeadAirClassifier.measure(samples, peak: peak(samples))

    #expect(measured.isDeadAir == false)
    #expect(RawAudioDeadAirClassifier.isDeadAir(samples, peak: peak(samples)) == false)
    let whole = try! #require(measured.wholeBufferRMS)
    let window = try! #require(measured.maxWindowRMS)
    #expect(window > whole, "the tiled loop must find a window louder than the whole buffer")
  }

  /// An `ArraySlice` does not start at index 0. The window loop indexes from
  /// `startIndex`, and #1317's cloud review caught this exact trap; `measure`
  /// inherits the loop so it inherits the obligation.
  @Test("measure agrees for an Array and a non-zero-offset slice of the same values")
  func measureAgreesAcrossSliceOffset() {
    var backing = [Float](repeating: 0.9, count: 1_000)
    backing.append(contentsOf: [Float](repeating: 0.001, count: 16_000))
    let slice = backing[1_000...]
    let array = Array(slice)

    let slicePeak = slice.reduce(Float(0)) { max($0, abs($1)) }
    let arrayResult = RawAudioDeadAirClassifier.measure(array, peak: peak(array))
    let sliceResult = RawAudioDeadAirClassifier.measure(slice, peak: slicePeak)

    #expect(arrayResult == sliceResult, "slice offset changed the measurement")
  }

  // MARK: Short-circuit fidelity — nil means NOT COMPUTED

  /// An above-floor peak returns before any RMS work. Both values must be nil.
  /// If either came back `0`, a caller could not tell "we never looked" from
  /// "we looked and the line is dead", which is the whole point of #1845.
  @Test("an above-floor peak reports both RMS values as nil, never zero")
  func abovePeakFloorReportsNilNotZero() {
    let samples = [Float](repeating: 0.5, count: 16_000)

    let measured = RawAudioDeadAirClassifier.measure(samples, peak: peak(samples))

    #expect(measured.isDeadAir == false)
    #expect(measured.wholeBufferRMS == nil, "not computed must not be reported as a value")
    #expect(measured.maxWindowRMS == nil, "not computed must not be reported as a value")
  }

  /// An empty buffer is dead air by definition and computes no RMS at all.
  @Test("an empty buffer is dead air with both RMS values nil")
  func emptyBufferReportsNil() {
    let measured = RawAudioDeadAirClassifier.measure([Float](), peak: 0)

    #expect(measured.isDeadAir == true)
    #expect(measured.wholeBufferRMS == nil)
    #expect(measured.maxWindowRMS == nil)
  }

  /// Whole-buffer RMS above its floor returns before the window loop, so the
  /// whole-buffer value IS known and the window value is not. This is the row
  /// that proves the two optionals are independent rather than moving together.
  @Test("an above-floor whole-buffer RMS reports that value but a nil window value")
  func aboveWholeBufferRMSReportsPartialMeasurement() {
    let samples = [Float](repeating: 0.0013, count: 16_000)

    let measured = RawAudioDeadAirClassifier.measure(samples, peak: peak(samples))

    #expect(measured.isDeadAir == false)
    #expect(measured.wholeBufferRMS != nil, "it was computed, so it must be reported")
    #expect(measured.maxWindowRMS == nil, "the window loop never ran")
  }

  /// A buffer shorter than one 40 ms window has no tiled window, so the
  /// whole-buffer RMS is legitimately BOTH values. Distinct from the nil cases
  /// above: here the window value is known, and happens to equal the other.
  @Test("a sub-window buffer reports the whole-buffer RMS as both values")
  func shortBufferReusesWholeBufferRMS() {
    let samples = [Float](repeating: 0.001, count: 320)

    let measured = RawAudioDeadAirClassifier.measure(samples, peak: peak(samples))

    #expect(measured.isDeadAir == true)
    let whole = try! #require(measured.wholeBufferRMS)
    let window = try! #require(measured.maxWindowRMS)
    #expect(whole == window, "a sub-window buffer's loudest window is the whole buffer")
  }

  // MARK: #4154 D-Q: exact-zero runs left out of the whole-buffer RMS decision

  /// 1 s of `.0013`, `zeros` exact zeros, 1 s of `.0013`. The quiet level alone
  /// clears the 0.00125 whole-buffer floor; peak and window values stay under
  /// theirs, so the whole-buffer term is the only one that can keep it alive.
  private func quietPause(zeros: Int, leading: Int = 0, trailing: Int = 0) -> [Float] {
    [Float](repeating: 0, count: leading)
      + [Float](repeating: 0.0013, count: 16_000)
      + [Float](repeating: 0, count: zeros)
      + [Float](repeating: 0.0013, count: 16_000)
      + [Float](repeating: 0, count: trailing)
  }

  /// When this fails, a USB user's quiet sentence with a long pause in the
  /// middle is thrown away as "no speech". The default call is today's
  /// verdict: the 5 s pause dilutes the quiet speech to dead air.
  @Test("a long interior zero run no longer dilutes quiet input to dead air")
  func interiorZeroRunDoesNotDiluteQuietInput() throws {
    let samples = quietPause(zeros: 80_000)
    let p = peak(samples)

    let today = RawAudioDeadAirClassifier.measure(samples, peak: p)
    let excluding = RawAudioDeadAirClassifier.measure(
      samples, peak: p, excludingExactZeroRunsOfAtLeast: 16_000)

    #expect(today.isDeadAir == true, "baseline: the default call must keep today's verdict")
    #expect(today.wholeBufferRMSExcludingZeroRuns == nil)
    #expect(excluding.isDeadAir == false)
    let raw = try #require(excluding.wholeBufferRMS)
    let decision = try #require(excluding.wholeBufferRMSExcludingZeroRuns)
    #expect(abs(raw - 0.000_695) < 0.000_005, "raw RMS keeps its whole-buffer meaning")
    #expect(raw == today.wholeBufferRMS, "raw RMS must not change when the decision mode is on")
    #expect(abs(decision - 0.0013) < 0.000_005)
    #expect(
      excluding.maxWindowRMS == nil, "the whole-buffer term decided; the window loop never ran")
  }

  /// Only runs of at least `minRun` leave the denominator, wherever they sit.
  /// 15,999 is one short of the bar and stays in; leading and trailing runs
  /// count the same as interior ones.
  @Test(
    "only exact-zero runs of at least the minimum length leave the denominator",
    arguments: [
      // (label, zeros, leading, trailing, excluded)
      ("interior one short of the bar", 15_999, 0, 0, false),
      ("interior exactly the bar", 16_000, 0, 0, true),
      ("interior one past the bar", 16_001, 0, 0, true),
      ("leading run", 0, 16_000, 0, true),
      ("trailing run", 0, 0, 16_000, true),
    ] as [(String, Int, Int, Int, Bool)]
  )
  func runLengthBoundaries(
    label: String, zeros: Int, leading: Int, trailing: Int, excluded: Bool
  ) throws {
    let samples = quietPause(zeros: zeros, leading: leading, trailing: trailing)
    let measured = RawAudioDeadAirClassifier.measure(
      samples, peak: peak(samples), excludingExactZeroRunsOfAtLeast: 16_000)

    let raw = try #require(measured.wholeBufferRMS, "\(label)")
    let decision = try #require(measured.wholeBufferRMSExcludingZeroRuns, "\(label)")
    if excluded {
      #expect(abs(decision - 0.0013) < 0.000_005, "\(label): run must leave the denominator")
      #expect(decision > raw, "\(label)")
    } else {
      #expect(decision == raw, "\(label): a short run must stay in the denominator")
    }
  }

  /// A buffer that is nothing but a qualifying run has an empty denominator.
  /// The decision value is a finite 0, never NaN, and the take stays dead air
  /// through the unchanged window loop.
  @Test("an all-zero buffer gets a decision RMS of 0 and stays dead air")
  func allZeroBufferStaysDeadAir() throws {
    let samples = [Float](repeating: 0, count: 32_000)
    let measured = RawAudioDeadAirClassifier.measure(
      samples, peak: 0, excludingExactZeroRunsOfAtLeast: 16_000)

    #expect(measured.isDeadAir == true)
    let decision = try #require(measured.wholeBufferRMSExcludingZeroRuns)
    #expect(decision == 0)
    #expect(decision.isNaN == false)
    #expect(measured.wholeBufferRMS == 0)
    #expect(measured.maxWindowRMS == 0)
  }

  /// Below-floor input stays dead air with the exclusion on: removing zeros
  /// lifts the average only to the level the input really had.
  @Test("below-floor input plus a long zero run stays dead air")
  func belowFloorInputStaysDeadAir() {
    let samples =
      [Float](repeating: 0.001, count: 16_000) + [Float](repeating: 0, count: 80_000)
    let measured = RawAudioDeadAirClassifier.measure(
      samples, peak: peak(samples), excludingExactZeroRunsOfAtLeast: 16_000)

    #expect(measured.isDeadAir == true)
    #expect(measured.maxWindowRMS != nil, "the window loop ran and agreed")
  }

  /// With no qualifying run the decision equals the raw value and every tuned
  /// shape keeps its verdict, so turning the mode on changes nothing else.
  @Test("with no qualifying run the exclusion mode keeps every tuned verdict")
  func exclusionModeKeepsTunedVerdicts() {
    let shapes: [[Float]] = [
      [Float](repeating: 0.001, count: 16_000),
      [Float](repeating: 0.0011, count: 16_000),
      [Float](repeating: 0.0013, count: 16_000),
      [Float](repeating: 0.001, count: 320),
      [Float](repeating: 0.0025, count: 320),
    ]
    for samples in shapes {
      let p = peak(samples)
      let today = RawAudioDeadAirClassifier.measure(samples, peak: p)
      let excluding = RawAudioDeadAirClassifier.measure(
        samples, peak: p, excludingExactZeroRunsOfAtLeast: 16_000)
      #expect(excluding.isDeadAir == today.isDeadAir)
      #expect(excluding.wholeBufferRMS == today.wholeBufferRMS)
      #expect(excluding.maxWindowRMS == today.maxWindowRMS)
      #expect(excluding.wholeBufferRMSExcludingZeroRuns == today.wholeBufferRMS)
    }
  }

  /// The run counter walks the slice's own indices, like the window loop.
  @Test("the exclusion agrees for an Array and a non-zero-offset slice")
  func exclusionAgreesAcrossSliceOffset() {
    var backing = [Float](repeating: 0.9, count: 1_000)
    backing.append(contentsOf: quietPause(zeros: 80_000))
    let slice = backing[1_000...]
    let array = Array(slice)

    let slicePeak = slice.reduce(Float(0)) { max($0, abs($1)) }
    let arrayResult = RawAudioDeadAirClassifier.measure(
      array, peak: peak(array), excludingExactZeroRunsOfAtLeast: 16_000)
    let sliceResult = RawAudioDeadAirClassifier.measure(
      slice, peak: slicePeak, excludingExactZeroRunsOfAtLeast: 16_000)

    #expect(arrayResult == sliceResult, "slice offset changed the measurement")
    #expect(sliceResult.isDeadAir == false)
  }

  // MARK: #3834 advisory bar

  /// When this fails, the user sees "Audio isn't capturing" after a short tap
  /// or a quiet-room take, or misses it on a long genuinely dead take. Each row
  /// sits on one side of one boundary: 30 ticks, a peak strictly under 0.0018,
  /// a missing tick reading, and a disabled bar.
  @Test(
    "meetsAdvisoryBar selects only long takes that stayed below the peak bar",
    arguments: [
      // (label, visibleTicks, minimumTicks, peak, expected)
      ("one tick short", UInt64(29), 30, Float(0), false),
      ("exactly the duration bar, digital zero", UInt64(30), 30, Float(0), true),
      ("just under the peak bar", UInt64(30), 30, Float(0.00179), true),
      ("peak equal to the bar", UInt64(30), 30, Float(0.0018), false),
      ("missing tick reading", nil, 30, Float(0), false),
      ("long but louder than the bar", UInt64(600), 30, Float(0.005), false),
      ("disabled bar", UInt64(600), 0, Float(0), false),
    ] as [(String, UInt64?, Int, Float, Bool)]
  )
  func advisoryBar(
    label: String, visibleTicks: UInt64?, minimumTicks: Int, peak: Float, expected: Bool
  ) {
    #expect(
      RawAudioDeadAirClassifier.meetsAdvisoryBar(
        visibleTicks: visibleTicks, minimumTicks: minimumTicks, peak: peak) == expected,
      "\(label)")
  }
}
