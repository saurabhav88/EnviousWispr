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
}
