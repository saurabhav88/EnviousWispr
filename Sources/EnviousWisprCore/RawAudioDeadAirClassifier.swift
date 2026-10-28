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

  /// #3834: when a dead-air take is worth telling the user about.
  /// Short takes and quiet working microphones can also fall below the
  /// dead-air floors. Select the advisory only when visible recording reaches
  /// the duration bar and peak stays strictly below the peak bar.
  /// Presentation only: this does not establish whether speech occurred or
  /// whether the microphone worked, and never changes routing into ASR.
  public enum AdvisoryBar {
    /// Visible recording time required, based on superwhisper 3.0.0's
    /// measured 3.0-second dictation window (#3834).
    public static let minimumDurationSeconds: Double = 3.0
    /// Peak absolute amplitude required, based on superwhisper's 0x3aebedfa.
    /// This lies between the measured analog-muted headset peaks
    /// (0.0005-0.0010) and measured live-room peaks (0.0042 or more).
    public static let maximumPeak: Float = 0.0018
  }

  /// #3834: true when a dead-air take meets the advisory bar. `visibleTicks` is
  /// the kernel's visible-recording elapsed time in its own tick unit and
  /// `minimumTicks` the bar converted to that unit by the caller. A missing
  /// reading or a disabled bar selects silence: the goal is fewer false alarms.
  public static func meetsAdvisoryBar(visibleTicks: UInt64?, minimumTicks: Int, peak: Float)
    -> Bool
  {
    guard let visibleTicks, minimumTicks > 0 else { return false }
    return visibleTicks >= UInt64(minimumTicks) && peak < AdvisoryBar.maximumPeak
  }

  /// What `measure` observed while classifying a buffer (#1845).
  ///
  /// Both RMS values are OPTIONAL because the classification short-circuits:
  /// an above-floor peak, an empty buffer, or an above-floor whole-buffer RMS
  /// each return before the later work runs. `nil` therefore means "not
  /// computed", never "computed as zero" — the same distinction #1845 enforces
  /// on `peak_audio_level` at the telemetry layer, where a fabricated zero
  /// would be indistinguishable from a digitally dead channel.
  package struct DeadAirMeasurement: Sendable, Equatable {
    package let wholeBufferRMS: Float?
    package let maxWindowRMS: Float?
    /// #4154 (D-Q): decision-only whole-buffer RMS whose denominator leaves out
    /// exact-zero runs of at least the caller's `minRun`. `nil` when the caller
    /// did not ask for it or the classification returned before computing it.
    /// Never telemetry: `wholeBufferRMS` keeps its raw whole-buffer meaning.
    package let wholeBufferRMSExcludingZeroRuns: Float?
    package let isDeadAir: Bool

    package init(
      wholeBufferRMS: Float?, maxWindowRMS: Float?,
      wholeBufferRMSExcludingZeroRuns: Float? = nil, isDeadAir: Bool
    ) {
      self.wholeBufferRMS = wholeBufferRMS
      self.maxWindowRMS = maxWindowRMS
      self.wholeBufferRMSExcludingZeroRuns = wholeBufferRMSExcludingZeroRuns
      self.isDeadAir = isDeadAir
    }
  }

  /// The classification above, plus the intermediate energy values it computed.
  ///
  /// `isDeadAir` delegates here, so this is the single implementation of the
  /// #964 gate rather than a parallel copy. #1845 needs the two RMS values as
  /// telemetry: the classifier already computed them and threw them away, and
  /// recomputing them at the call site would be a second implementation of the
  /// thing being measured.
  ///
  /// With exclusion off (`nil`, every caller but one), short-circuit ORDER and
  /// RESULTS are identical to the pre-#1845 code —
  /// peak, then empty, then whole-buffer RMS, then the short-buffer reuse, then
  /// the tiled window loop. Nothing added here may change what the gate decides.
  ///
  /// #4154 (D-Q): `excludingExactZeroRunsOfAtLeast` is `nil` for every caller
  /// except the kernel's no-speech gate on a confirmed-bound USB take. With a
  /// value, the whole-buffer RMS COMPARISON uses a denominator that leaves out
  /// every run of exact 0.0 at least that long, so long digital silence cannot
  /// dilute quiet input that was audible on its own. Valid digital silence is
  /// ambiguous, so this is a deliberate averaging change for that one caller,
  /// not a claim that the zeros were "no audio". The sum of squares, the peak,
  /// sample positions and the 40 ms window loop are untouched, and an all-run
  /// buffer gets a decision RMS of 0 (never NaN) so it stays dead air. A
  /// non-positive length is treated as `nil`. Defaulted so the unchanged
  /// attribution call keeps today's literal call shape.
  package static func measure<C: RandomAccessCollection>(
    _ samples: C,
    peak: Float,
    excludingExactZeroRunsOfAtLeast minRun: Int? = nil
  ) -> DeadAirMeasurement
  where C.Element == Float, C.Index == Int {
    guard peak < DeadAirFloor.peak else {
      return DeadAirMeasurement(wholeBufferRMS: nil, maxWindowRMS: nil, isDeadAir: false)
    }
    guard !samples.isEmpty else {
      return DeadAirMeasurement(wholeBufferRMS: nil, maxWindowRMS: nil, isDeadAir: true)
    }
    let minRun = minRun.flatMap { $0 > 0 ? $0 : nil }
    var sumSquares: Float = 0
    var excludedCount = 0
    var zeroRun = 0
    for s in samples {
      sumSquares += s * s
      guard let minRun else { continue }
      if s == 0 {
        zeroRun += 1
      } else {
        if zeroRun >= minRun { excludedCount += zeroRun }
        zeroRun = 0
      }
    }
    if let minRun, zeroRun >= minRun { excludedCount += zeroRun }
    let rms = (sumSquares / Float(samples.count)).squareRoot()
    let decisionRMS: Float? = minRun.map { _ in
      let kept = samples.count - excludedCount
      return kept > 0 ? (sumSquares / Float(kept)).squareRoot() : 0
    }
    guard (decisionRMS ?? rms) < DeadAirFloor.rms else {
      return DeadAirMeasurement(
        wholeBufferRMS: rms, maxWindowRMS: nil,
        wholeBufferRMSExcludingZeroRuns: decisionRMS, isDeadAir: false)
    }
    // Loudest non-overlapping 40 ms window. A faint word lifts a local
    // window's RMS even when most of the buffer is silence around it; tiled
    // windows keep this bounded at O(n). Indices are offset from
    // `samples.startIndex`, not 0 — an `ArraySlice` (e.g. a prefix view into
    // a larger buffer, #1317 cloud review) does NOT start at index 0, so raw
    // `0..<window`-style indexing would read the wrong elements or trap.
    let window = DeadAirFloor.windowSamples
    guard samples.count >= window else {
      // A buffer shorter than one window has no tiled window to measure, so the
      // whole-buffer RMS IS the loudest-window value. Reported rather than left
      // nil: it was computed, and the gate compared it.
      return DeadAirMeasurement(
        wholeBufferRMS: rms, maxWindowRMS: rms,
        wholeBufferRMSExcludingZeroRuns: decisionRMS, isDeadAir: rms < DeadAirFloor.windowRms)
    }
    var maxWindowRms = rms
    var windowStart = samples.startIndex
    while windowStart + window <= samples.endIndex {
      var ss: Float = 0
      for j in windowStart..<(windowStart + window) { ss += samples[j] * samples[j] }
      let wr = (ss / Float(window)).squareRoot()
      if wr > maxWindowRms { maxWindowRms = wr }
      windowStart += window
    }
    return DeadAirMeasurement(
      wholeBufferRMS: rms, maxWindowRMS: maxWindowRms,
      wholeBufferRMSExcludingZeroRuns: decisionRMS,
      isDeadAir: maxWindowRms < DeadAirFloor.windowRms)
  }

  /// True when a raw capture buffer is dead air (no recoverable speech) for
  /// the #964 gate: when Silero reports zero segments the kernel skips ASR
  /// ONLY if the raw audio is also below every `DeadAirFloor` threshold.
  /// Otherwise it falls through and lets Parakeet decide. Pure + static so
  /// the boundary cases (just-below / just-above each threshold) unit-test
  /// without a kernel.
  ///
  /// #1845: now a projection of `measure`, which owns the computation. Callers
  /// that only need the verdict keep using this.
  public static func isDeadAir<C: RandomAccessCollection>(_ samples: C, peak: Float) -> Bool
  where C.Element == Float, C.Index == Int {
    measure(samples, peak: peak).isDeadAir
  }
}
