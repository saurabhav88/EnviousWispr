import Foundation

/// Shared dead-air (no recoverable speech) classifier for raw capture audio.
/// Moved out of `RecordingSessionKernel` (#1317 PR1) so `EnviousWisprAudio`'s
/// app-side all-zero detector and the kernel's own `#964` no-speech gate read
/// the same authority instead of two independent implementations drifting
/// apart.
public enum RawAudioDeadAirClassifier {
  /// Empirical dead-air energy thresholds for the #964 no-speech gate. See
  /// `isDeadAir`. Deliberately LOW — these reject only genuine silence, not
  /// an audible-but-faint utterance (measured -35 dB room noise peaks at
  /// 0.0178, above a real whisper at 0.0109, so signal level alone can't
  /// split faint speech from noise — Parakeet is the arbiter past this
  /// floor).
  public enum DeadAirFloor {
    /// Peak absolute amplitude (linear, Float32). ~ -44 dBFS.
    public static let peak: Float = 0.006
    /// Whole-buffer RMS.
    public static let rms: Float = 0.00125
    /// Loudest 40 ms window RMS — catches a faint word inside a mostly-silent
    /// buffer where the whole-buffer RMS stays low.
    public static let windowRms: Float = 0.002
    /// 40 ms at 16 kHz.
    public static let windowSamples = 640
  }

  /// True when a raw capture buffer is dead air (no recoverable speech) for
  /// the #964 gate: when Silero reports zero segments the kernel skips ASR
  /// ONLY if the raw audio is also below every `DeadAirFloor` threshold.
  /// Otherwise it falls through and lets Parakeet decide. Pure + static so
  /// the boundary cases (just-below / just-above each threshold) unit-test
  /// without a kernel.
  public static func isDeadAir<C: RandomAccessCollection>(_ samples: C, peak: Float) -> Bool
  where C.Element == Float, C.Index == Int {
    guard peak < DeadAirFloor.peak else { return false }
    guard !samples.isEmpty else { return true }
    var sumSquares: Float = 0
    for s in samples { sumSquares += s * s }
    let rms = (sumSquares / Float(samples.count)).squareRoot()
    guard rms < DeadAirFloor.rms else { return false }
    // Loudest non-overlapping 40 ms window. A faint word lifts a local
    // window's RMS even when most of the buffer is silence around it; tiled
    // windows keep this bounded at O(n). Indices are offset from
    // `samples.startIndex`, not 0 — an `ArraySlice` (e.g. a prefix view into
    // a larger buffer, #1317 cloud review) does NOT start at index 0, so raw
    // `0..<window`-style indexing would read the wrong elements or trap.
    let window = DeadAirFloor.windowSamples
    guard samples.count >= window else { return rms < DeadAirFloor.windowRms }
    var maxWindowRms = rms
    var windowStart = samples.startIndex
    while windowStart + window <= samples.endIndex {
      var ss: Float = 0
      for j in windowStart..<(windowStart + window) { ss += samples[j] * samples[j] }
      let wr = (ss / Float(window)).squareRoot()
      if wr > maxWindowRms { maxWindowRms = wr }
      windowStart += window
    }
    return maxWindowRms < DeadAirFloor.windowRms
  }
}
