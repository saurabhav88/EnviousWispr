/// #1317: per-capture-generation exact-zero counter, maintained incrementally as
/// buffers arrive (drained pre-roll first). #4841: observation only. It feeds the
/// silent-mic notice (`AudioCaptureManager.exactZeroRun`) and the DEBUG
/// `ZERO_PREFIX_MEASURE` diagnostic; exact zeros never end a take, and the stop
/// path classifies the whole buffer with `RawAudioDeadAirClassifier`, a separate
/// type.
struct DeadAirStreamingDetector {
  private(set) var totalSampleCount = 0
  /// Length of the current trailing run of exact-zero samples. Resets to 0 on
  /// any non-zero sample.
  private(set) var consecutiveExactZeroSuffix = 0

  mutating func ingest(_ samples: UnsafeBufferPointer<Float>) {
    for s in samples {
      // Latch the first non-zero position BEFORE incrementing, so the value is
      // the zero-prefix length in samples (#1788 diagnostic).
      if s != 0, firstNonZeroIndex == nil { firstNonZeroIndex = totalSampleCount }
      totalSampleCount += 1
      consecutiveExactZeroSuffix = s == 0 ? consecutiveExactZeroSuffix + 1 : 0
    }
  }

  /// Number of leading samples that were exactly zero before the first non-zero
  /// sample, or `nil` while the capture is still entirely zeros. Diagnostic only:
  /// on Bluetooth this is the SCO/HFP link wake time, which is otherwise
  /// unobservable (#1788).
  var zeroPrefixSampleCount: Int? {
    guard totalSampleCount > 0 else { return nil }
    // Still all-zero: the prefix has not ended, so there is nothing to report.
    guard consecutiveExactZeroSuffix != totalSampleCount else { return nil }
    return firstNonZeroIndex
  }

  /// Index of the first non-zero sample in this generation; `nil` until one
  /// arrives. Latched once — later zero runs do not move it.
  private(set) var firstNonZeroIndex: Int?
}
