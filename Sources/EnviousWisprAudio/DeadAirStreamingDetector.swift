import EnviousWisprCore

/// #1317: per-capture-generation streaming state for the app-side all-zero
/// harness-glitch detector. Maintains, incrementally as buffers arrive, the
/// SAME statistics `RawAudioDeadAirClassifier.isDeadAir` would compute over
/// the full concatenated sample array up to this point — so a streaming
/// classification made buffer-by-buffer agrees with a one-shot classification
/// made over the same samples after the fact, even when a 40 ms tile boundary
/// falls across two buffers (the split-buffer-boundary equivalence test).
///
/// Tiles are non-overlapping and capture-start-aligned (index 0 of the whole
/// capture, not per-buffer) — a sliding window would classify differently and
/// break that equivalence (`RawAudioDeadAirClassifier.isDeadAir`'s own
/// non-overlapping semantics, mirrored here).
struct DeadAirStreamingDetector {
  private(set) var totalSampleCount = 0
  private(set) var consecutiveExactZeroSuffix = 0
  private(set) var runningPeak: Float = 0
  private var runningSumSquares: Double = 0
  private var partialTileCount = 0
  private var partialTileSumSquares: Float = 0
  private(set) var maxCompletedTileRms: Float = 0
  /// Latches true the first time the accumulated prefix is evaluated as NOT
  /// dead air. One-way: does not un-set as later trailing zeros dilute the
  /// running whole-prefix average — "was there ever real signal" is the
  /// question, not "is the average right now above the floor."
  private(set) var meaningfulSignalSeen = false
  /// Set once a mode has been reported so the caller ingests without
  /// re-evaluating a capture already handed off for recovery.
  var fired = false

  private var window: Int { RawAudioDeadAirClassifier.DeadAirFloor.windowSamples }

  mutating func ingest(_ samples: UnsafeBufferPointer<Float>) {
    guard !fired else { return }
    for s in samples {
      // Latch the first non-zero position BEFORE incrementing, so the value is
      // the zero-prefix length in samples (#1788 diagnostic).
      if s != 0, firstNonZeroIndex == nil { firstNonZeroIndex = totalSampleCount }
      totalSampleCount += 1
      let a = abs(s)
      if a > runningPeak { runningPeak = a }
      runningSumSquares += Double(s) * Double(s)
      consecutiveExactZeroSuffix = s == 0 ? consecutiveExactZeroSuffix + 1 : 0
      partialTileSumSquares += s * s
      partialTileCount += 1
      if partialTileCount == window {
        let tileRms = (partialTileSumSquares / Float(window)).squareRoot()
        if tileRms > maxCompletedTileRms { maxCompletedTileRms = tileRms }
        partialTileCount = 0
        partialTileSumSquares = 0
      }
    }
    updateMeaningfulSignalSeen()
  }

  private mutating func updateMeaningfulSignalSeen() {
    guard !meaningfulSignalSeen, totalSampleCount > 0 else { return }
    let rms = Float((runningSumSquares / Double(totalSampleCount)).squareRoot())
    let floor = RawAudioDeadAirClassifier.DeadAirFloor.self
    let isDeadAirSoFar =
      runningPeak < floor.peak
      && rms < floor.rms
      && maxCompletedTileRms < floor.windowRms
    if !isDeadAirSoFar { meaningfulSignalSeen = true }
  }

  /// `total received >= ceilingSamples AND every received sample exactly zero`
  /// (#1317 §3.1).
  ///
  /// The ceiling is supplied by the caller rather than read from
  /// `AudioConstants` so this struct stays sample-only — it owns no transport,
  /// device, or policy knowledge, and the boundary is unit-testable without a
  /// capture manager. `AudioCaptureManager.allZeroCeilingSamples` is the single
  /// production caller and the sole owner of what the ceiling should be (#1788).
  ///
  /// One-way by construction: `consecutiveExactZeroSuffix` resets to 0 on any
  /// non-zero sample (`ingest`) while `totalSampleCount` only grows, so once
  /// real audio arrives this can never be true again for that generation. A
  /// microphone that wakes up therefore cannot be aborted later in the same take.
  func isAllZeroFromStart(ceilingSamples: Int) -> Bool {
    totalSampleCount >= ceilingSamples
      && consecutiveExactZeroSuffix == totalSampleCount
  }

  /// Number of leading samples that were exactly zero before the first non-zero
  /// sample, or `nil` while the capture is still entirely zeros. Diagnostic only:
  /// on Bluetooth this is the SCO/HFP link wake time, which is otherwise
  /// unobservable because the abort fires before a slow wake completes (#1788).
  var zeroPrefixSampleCount: Int? {
    guard totalSampleCount > 0 else { return nil }
    // Still all-zero: the prefix has not ended, so there is nothing to report.
    guard consecutiveExactZeroSuffix != totalSampleCount else { return nil }
    return firstNonZeroIndex
  }

  /// Index of the first non-zero sample in this generation; `nil` until one
  /// arrives. Latched once — later zero runs do not move it.
  private(set) var firstNonZeroIndex: Int?

  /// `meaningfulSignalSeen was set, then a sustained suffix of >=
  /// minimumTranscriptionSamples CONSECUTIVE exact-zero samples` (#1317 §3.1).
  var isBecameZeroMidCapture: Bool {
    meaningfulSignalSeen
      && consecutiveExactZeroSuffix >= AudioConstants.minimumTranscriptionSamples
  }
}
