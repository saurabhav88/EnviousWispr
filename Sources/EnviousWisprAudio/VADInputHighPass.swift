import EnviousWisprCore
import Foundation

/// Removes sub-250 Hz energy from a chunk of samples on its way into the VAD
/// model, and from nothing else (#2184).
///
/// ## Why this exists
///
/// In a sustained low-frequency noise field — an aeroplane cabin, an extractor
/// fan, HVAC at close range — the Silero VAD misclassifies speech as silence.
/// Its segments trim the buffer the ASR decodes, so the user receives a fluent,
/// confident transcript missing its opening words. Measured on 36 labelled
/// clips from the founder's own archive, decoded by the shipped Parakeet v3:
/// mean word survival 90.2% → 98.0%, clips losing >10% of their words 6 → 1.
/// False alarms on 32 labelled non-speech clips *improve*, 28% → 19%.
///
/// ## What must not change
///
/// **The filtered array reaches the VAD model and nothing else.** The ASR input,
/// the pre-roll buffer, Live Preview's snapshot, the dictation archive and the
/// energy gate all keep reading raw samples. The energy gate in particular: this
/// filter *removes* energy, so a gate reading filtered audio would zero more
/// chunks and silently become a stricter soft-speech threshold — the opposite of
/// the intent. `SilenceDetector.processChunk` is the single call site and is
/// where that separation is enforced.
///
/// **250 is the per-section parameter, not the cascade's −3 dB point.** It is
/// the value substituted into each section's `RC = 1 / (2π × 250)`, exactly as
/// the measurement harness computed it. A Butterworth biquad "at 250 Hz" is a
/// different filter and invalidates every number above; 150 Hz is measurably
/// worse than both ends (it destroys two loud clips that were intact at 100% and
/// at today's behaviour). 300 Hz is word-level identical and more aggressive in
/// the band where soft voices live, so 250 is the conservative point on a
/// plateau rather than a peak. Do not retune without rerunning the gates in
/// `docs/feature-requests/issue-2184-2026-08-18-noise-robust-dictation.md` §13.
///
/// ## Contract
///
/// Deterministic, stateful, length-preserving; no failure mode and no error
/// return. Chunks must be fed **in order within a recording session**, and
/// `reset()` must be called between sessions — the sections are IIR, so state
/// carries across the 4096-sample chunk boundaries by design, and reusing state
/// across sessions would condition a session's first chunks on the previous
/// one's audio. Feeding a session's chunks in order and resetting between them
/// yields output bit-identical to filtering that session's whole buffer at once.
struct VADInputHighPass {
  /// The value substituted into each section's `RC`. **Not** the cascade's
  /// −3 dB point — see the type doc.
  static let parameterHz: Double = 250

  /// Two cascaded sections, i.e. the measured ~12 dB/octave form.
  static let sectionCount = 2

  /// One `y[n] = a × (y[n−1] + x[n] − x[n−1])` section. Double state and
  /// arithmetic with Float input and output: at 16 kHz the coefficient sits at
  /// roughly 0.99, so Float state accumulates visible error over a chunk.
  private struct Section {
    let a: Double
    var previousInput: Double = 0
    var previousOutput: Double = 0

    init(parameterHz: Double, sampleRate: Double) {
      let rc = 1.0 / (2.0 * Double.pi * parameterHz)
      a = rc / (rc + 1.0 / sampleRate)
    }

    mutating func process(_ x: Double) -> Double {
      let y = a * (previousOutput + x - previousInput)
      previousInput = x
      previousOutput = y
      return y
    }

    mutating func reset() {
      previousInput = 0
      previousOutput = 0
    }
  }

  private var sections: [Section]

  init(
    parameterHz: Double = VADInputHighPass.parameterHz,
    sampleRate: Double = AudioConstants.sampleRate,
    sectionCount: Int = VADInputHighPass.sectionCount
  ) {
    sections = (0..<max(0, sectionCount)).map { _ in
      Section(parameterHz: parameterHz, sampleRate: sampleRate)
    }
  }

  /// Filter one chunk, advancing the section state. Same length out as in.
  mutating func process(_ samples: [Float]) -> [Float] {
    guard !sections.isEmpty, !samples.isEmpty else { return samples }
    var out = samples
    for index in out.indices {
      var value = Double(out[index])
      for section in sections.indices {
        value = sections[section].process(value)
      }
      out[index] = Float(value)
    }
    return out
  }

  /// Zero every section's state. Called where the detector resets, so a new
  /// recording session never inherits the previous one's tail.
  mutating func reset() {
    for index in sections.indices {
      sections[index].reset()
    }
  }
}
