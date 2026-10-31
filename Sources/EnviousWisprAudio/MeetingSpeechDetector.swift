import EnviousWisprCore
@preconcurrency import FluidAudio
import Foundation

/// What a live window holds, as far as the detector has classified it (#4254 plan §16.2).
public enum MeetingSpeechWindow: Sendable, Equatable {
  /// Every sample of the window was classified, and none is speech.
  case silent
  /// Speech ranges inside the window (padded, merged, clamped to it; absolute sample indices).
  case speech([Range<Int>])
  /// Part of the window is not classified yet and the classified part holds no speech.
  case unknown
}

/// Silero speech detection for meeting Whisper (#4254), with dictation's settings and input
/// conditioning (`SpeechVADSettings`, `VADInputHighPass`), so meeting and dictation agree on
/// what speech is.
///
/// Two uses, each with its own instance and lifetime, never cached:
/// - Final pass: `spans(in:)` on a fresh detector for one decode input (one run, one retry),
///   released when that decode returns.
/// - Live words: one detector per track session. `append(_:)` feeds each accepted sample once,
///   indexed from session sample zero; `window(_:)` answers for a retained decode window;
///   `prune(before:)` drops ranges no window can reach. Released with the session.
///
/// Samples go to the model in 4,096-sample chunks (256 ms), conditioned by the high-pass on
/// the model's copy only. A partial chunk waits for more audio; at end of input it is padded
/// privately and every boundary is clamped to the real samples. Speech still open at end of
/// input is closed at the last real sample, as dictation's `finalizeSegments` does.
///
/// A detector error stops the detector for good: its recurrent state never resumes across audio
/// it did not process. Callers choose what an error means (the plan fails open per decode, and
/// disables live detection for the rest of a session). Cancellation is reported as cancellation.
public actor MeetingSpeechDetector {
  public enum DetectorError: Error, Equatable {
    /// A previous error stopped this detector.
    case stopped
  }

  static let chunkSize = SilenceDetector.chunkSize
  /// Dictation's default silence timeout: a pause shorter than this stays inside one speech
  /// range, so a breath never splits a sentence.
  static let minimumSilenceSeconds: TimeInterval = 1.5

  private let makeStreamingVad: @Sendable () async throws -> any StreamingVad
  private var vad: (any StreamingVad)?
  private var state: VadStreamState = .initial()
  private var highPass = VADInputHighPass()
  private let segmentation = SpeechVADSettings.segmentation(
    minSilence: MeetingSpeechDetector.minimumSilenceSeconds)
  /// Accepted samples not yet a whole chunk.
  private var pending: [Float] = []
  /// Samples the model has classified (whole chunks only, before end of input).
  private var classified = 0
  /// Closed speech ranges, unpadded, absolute.
  private var closedSpans: [Range<Int>] = []
  private var openStart: Int?
  private var failed = false

  /// The pinned bundled model from `modelBundle` (the app's own bundle in production).
  public init(modelBundle: Bundle = .main) {
    self.init(makeStreamingVad: {
      SpeechVADSettings.manager(model: try BundledVADModelLoader.loadModel(in: modelBundle))
    })
  }

  /// Test seam: a fake streaming VAD.
  init(makeStreamingVad: @Sendable @escaping () async throws -> any StreamingVad) {
    self.makeStreamingVad = makeStreamingVad
    pending.reserveCapacity(Self.chunkSize)
  }

  // MARK: - Final pass

  /// The padded, merged speech ranges of one whole decode input, on a fresh detector. Empty
  /// means no speech. Throws `CancellationError` when the task is cancelled, or the detector's
  /// error.
  public static func spans(in samples: [Float], modelBundle: Bundle = .main) async throws
    -> [Range<Int>]
  {
    try await MeetingSpeechDetector(modelBundle: modelBundle).finalSpans(samples)
  }

  func finalSpans(_ samples: [Float]) async throws -> [Range<Int>] {
    var offset = 0
    while offset < samples.count {
      try Task.checkCancellation()
      let end = min(offset + Self.chunkSize, samples.count)
      try await append(Array(samples[offset..<end]))
      offset = end
    }
    try await finish()
    return Self.padded(closedSpans, within: 0..<samples.count)
  }

  // MARK: - Continuous (live)

  /// Feeds newly accepted samples, in order, each exactly once. Whole chunks are classified
  /// now; a remainder waits for more.
  public func append(_ samples: [Float]) async throws {
    guard !failed else { throw DetectorError.stopped }
    var offset = 0
    while offset < samples.count {
      let take = min(Self.chunkSize - pending.count, samples.count - offset)
      pending.append(contentsOf: samples[offset..<(offset + take)])
      offset += take
      if pending.count == Self.chunkSize {
        try await classify(pending, realCount: Self.chunkSize)
        pending.removeAll(keepingCapacity: true)
      }
    }
  }

  /// End of input: classifies the waiting remainder (padded privately) and closes open speech
  /// at the last real sample.
  public func finish() async throws {
    guard !failed else { throw DetectorError.stopped }
    if !pending.isEmpty {
      let real = pending.count
      var chunk = pending
      chunk.append(contentsOf: [Float](repeating: 0, count: Self.chunkSize - real))
      try await classify(chunk, realCount: real)
      pending.removeAll(keepingCapacity: true)
    }
    if let start = openStart {
      if classified > start { closedSpans.append(start..<classified) }
      openStart = nil
    }
  }

  /// What `window` (absolute indices) holds so far.
  public func window(_ window: Range<Int>) -> MeetingSpeechWindow {
    var raw = closedSpans
    if let start = openStart, classified > start { raw.append(start..<classified) }
    let speech = Self.padded(raw, within: window)
    if !speech.isEmpty { return .speech(speech) }
    return window.upperBound <= classified ? .silent : .unknown
  }

  /// Drops closed ranges whose padded end is at or before `sample`.
  public func prune(before sample: Int) {
    closedSpans.removeAll { $0.upperBound + AudioConstants.speechPaddingSamples <= sample }
  }

  /// Samples classified so far (the live clock), excluding a waiting remainder.
  public var classifiedSamples: Int { classified }

  /// The closed speech ranges before padding (tests compare them with dictation's segments).
  var unpaddedSpans: [Range<Int>] { closedSpans }

  // MARK: - Model

  private func classify(_ chunk: [Float], realCount: Int) async throws {
    do {
      if vad == nil { vad = try await makeStreamingVad() }
      guard let vad else { return }
      let result = try await vad.processStreamingChunk(
        highPass.process(chunk), state: state, config: segmentation, returnSeconds: false,
        timeResolution: 1)
      state = result.state
      let base = classified
      let limit = base + realCount
      if let event = result.event {
        // The stream clock counts whole chunks; boundaries never pass the real samples.
        let at = min(event.sampleIndex, limit)
        switch event.kind {
        case .speechStart:
          if openStart == nil { openStart = at }
        case .speechEnd:
          if let start = openStart {
            if at > start { closedSpans.append(start..<at) }
            openStart = nil
          }
        }
      }
      classified = limit
    } catch is CancellationError {
      failed = true
      throw CancellationError()
    } catch {
      failed = true
      throw error
    }
  }

  // MARK: - Ranges

  /// Each range widened by the shared padding, clamped to `bounds`, and merged where padded
  /// ranges touch or overlap.
  static func padded(_ ranges: [Range<Int>], within bounds: Range<Int>) -> [Range<Int>] {
    let pad = AudioConstants.speechPaddingSamples
    var out: [Range<Int>] = []
    for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
      let lower = max(bounds.lowerBound, range.lowerBound - pad)
      let upper = min(bounds.upperBound, range.upperBound + pad)
      guard upper > lower else { continue }
      if let last = out.last, lower <= last.upperBound {
        out[out.count - 1] = last.lowerBound..<max(last.upperBound, upper)
      } else {
        out.append(lower..<upper)
      }
    }
    return out
  }
}
