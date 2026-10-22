import Foundation

/// Picks where to cut a long meeting track into pieces for the speech engine (#3972 R16).
///
/// Peer practice: FluidVoice runs its final Parakeet pass over 60-second chunks; WhisperX cuts at
/// pauses. This cuts in the QUIETEST moment near the target length, from 30 ms RMS frames, with
/// no speech model and no audio ever skipped: every sample belongs to exactly one piece. Fixed
/// 5-minute cuts lost words at the joins in the #2648 long-file measurement, which is why the
/// cut looks for silence first.
public enum MeetingPauseFinder {
  public struct Configuration: Sendable, Equatable {
    public var sampleRate: Double = 16_000
    public var targetSeconds: Double = 60
    /// The cut is searched within target ± this.
    public var searchSeconds: Double = 15
    public var frameSeconds: Double = 0.03
    /// The quiet run the cut lands in.
    public var quietRunSeconds: Double = 0.3
    /// A cut whose quietest run is louder than this share of the window's median frame energy
    /// is a forced cut inside continuous speech (counted, never avoided by dropping audio).
    public var quietShareOfMedian: Double = 0.25

    public init() {}
  }

  public struct Cut: Sendable, Equatable {
    /// Sample offset where the next piece starts.
    public let sample: Int
    /// True when no quiet run was found and the cut landed inside speech.
    public let forced: Bool
  }

  /// Cut points for a contiguous run of `sampleCount` samples, given its samples. Offsets are
  /// strictly increasing and inside `1..<sampleCount`; a run shorter than target + search has
  /// no cut.
  public static func cuts(
    in samples: UnsafeBufferPointer<Float>, configuration c: Configuration = .init()
  )
    -> [Cut]
  {
    let count = samples.count
    let frame = max(1, Int(c.frameSeconds * c.sampleRate))
    let target = Int(c.targetSeconds * c.sampleRate)
    let search = Int(c.searchSeconds * c.sampleRate)
    let runFrames = max(1, Int((c.quietRunSeconds / c.frameSeconds).rounded()))
    var cuts: [Cut] = []
    var pieceStart = 0
    while count - pieceStart > target + search {
      let lo = pieceStart + target - search
      let hi = min(count - frame, pieceStart + target + search)
      let energies = frameEnergies(samples, from: lo, to: hi, frame: frame)
      guard energies.count >= runFrames else { break }
      // Lowest mean energy over `runFrames` consecutive frames; ties prefer the run nearest the
      // target so pieces stay close to the target length. Each window is summed afresh (a
      // sliding sum drifts in floating point, which turns two equally silent pauses unequal).
      let targetFrame = (pieceStart + target - lo) / frame
      var best = Float.greatestFiniteMagnitude
      var bestIndex = 0
      for i in 0...(energies.count - runFrames) {
        var window: Float = 0
        for k in i..<(i + runFrames) { window += energies[k] }
        if window < best || (window == best && abs(i - targetFrame) < abs(bestIndex - targetFrame)) {
          best = window
          bestIndex = i
        }
      }
      let sorted = energies.sorted()
      let median = sorted[sorted.count / 2]
      let forced = best / Float(runFrames) > Float(c.quietShareOfMedian) * median
      // Cut in the middle of the quiet run.
      let cut = lo + (bestIndex + runFrames / 2) * frame
      guard cut > pieceStart, cut < count else { break }
      cuts.append(Cut(sample: cut, forced: forced))
      pieceStart = cut
    }
    return cuts
  }

  public static func cuts(in samples: [Float], configuration: Configuration = .init()) -> [Cut] {
    samples.withUnsafeBufferPointer { cuts(in: $0, configuration: configuration) }
  }

  static func frameEnergies(
    _ samples: UnsafeBufferPointer<Float>, from lo: Int, to hi: Int, frame: Int
  )
    -> [Float]
  {
    guard hi > lo else { return [] }
    var energies: [Float] = []
    energies.reserveCapacity((hi - lo) / frame + 1)
    var start = lo
    while start + frame <= hi {
      var sum: Float = 0
      for i in start..<(start + frame) { sum += samples[i] * samples[i] }
      energies.append(sum / Float(frame))
      start += frame
    }
    return energies
  }
}
