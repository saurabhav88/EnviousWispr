import EnviousWisprCore
@preconcurrency import FluidAudio
import Foundation

/// One atomic look at a live window (#4254 plan §18 c3.1): what the detector knows about it,
/// taken in one actor turn so the three parts always agree.
public struct MeetingLiveSpeech: Sendable, Equatable {
  /// Speech ranges inside the window (padded, merged, clamped to it; absolute indices).
  public let speech: [Range<Int>]
  /// Whether speech is still open (started and not yet closed by a silence).
  public let speechOpen: Bool
  /// Samples classified so far (absolute); later samples are unknown.
  public let classifiedEnd: Int

  public init(speech: [Range<Int>], speechOpen: Bool, classifiedEnd: Int) {
    self.speech = speech
    self.speechOpen = speechOpen
    self.classifiedEnd = classifiedEnd
  }
}

/// Silero speech detection for meeting Whisper (#4254), with dictation's settings and input
/// conditioning (`SpeechVADSettings`, `VADInputHighPass`), so meeting and dictation agree on
/// what speech is.
///
/// Two uses, each with its own instance and lifetime, never cached:
/// - Final pass: `spans(in:)` on a fresh detector for one decode input (one run, one retry),
///   released when that decode returns.
/// - Live words: one detector per track session. `append(_:)` feeds each accepted sample once,
///   indexed from session sample zero; `liveSpeech(in:)` answers for a retained decode window;
///   `prune(before:)` drops ranges no window can reach. Released with the session.
///
/// Samples go to the model in 4,096-sample chunks (256 ms), conditioned by the high-pass on
/// the model's copy only. A partial chunk waits for more audio; at end of input it is padded
/// privately and every boundary is clamped to the real samples. Speech still open at end of
/// input is closed at the last real sample, as dictation's `finalizeSegments` does.
///
/// A detector error stops the detector for good: its recurrent state never resumes across audio
/// it did not process. Callers choose what an error means (the plan fails open per decode, and
/// disables live detection for the rest of a session). Cancellation is reported as cancellation,
/// and a cancelled detector is stopped too, since its caller cannot know which samples it took.
///
/// `append` and `finish` run one at a time, in call order, across their awaits (an actor alone
/// would let a second call interleave with the first's model call and reuse its stale state).
public actor MeetingSpeechDetector {
  public enum DetectorError: Error, Equatable {
    /// A previous error stopped this detector.
    case stopped
  }

  static let chunkSize = SilenceDetector.chunkSize
  /// #4254: the pinned model's name, for the meeting decode's counts-only log.
  package static let modelVersion = BundledVADModelLoader.pinnedModelName
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
  /// One `append`/`finish` at a time: true while one runs; later callers wait in call order.
  private var busy = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  /// Test seam: runs when a call starts waiting behind another.
  private let onWait: (@Sendable () -> Void)?

  /// The pinned bundled model from `modelBundle` (the app's own bundle in production).
  public init(modelBundle: Bundle = .main) {
    self.init(makeStreamingVad: {
      SpeechVADSettings.manager(model: try BundledVADModelLoader.loadModel(in: modelBundle))
    })
  }

  /// Test seam: a fake streaming VAD, and a hook for a call that starts waiting.
  init(
    makeStreamingVad: @Sendable @escaping () async throws -> any StreamingVad,
    onWait: (@Sendable () -> Void)? = nil
  ) {
    self.makeStreamingVad = makeStreamingVad
    self.onWait = onWait
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
    try Task.checkCancellation()
    return Self.padded(closedSpans, within: 0..<samples.count)
  }

  // MARK: - Continuous (live)

  /// Feeds newly accepted samples, in order, each exactly once. Whole chunks are classified
  /// now; a remainder waits for more.
  public func append(_ samples: [Float]) async throws {
    await acquire()
    defer { release() }
    guard !failed else { throw DetectorError.stopped }
    try stopIfCancelled()
    var offset = 0
    while offset < samples.count {
      let take = min(Self.chunkSize - pending.count, samples.count - offset)
      pending.append(contentsOf: samples[offset..<(offset + take)])
      offset += take
      if pending.count == Self.chunkSize {
        let chunk = pending
        pending.removeAll(keepingCapacity: true)
        try await classify(chunk, realCount: Self.chunkSize)
      }
    }
  }

  /// End of input: classifies the waiting remainder (padded privately) and closes open speech
  /// at the last real sample.
  public func finish() async throws {
    await acquire()
    defer { release() }
    guard !failed else { throw DetectorError.stopped }
    try stopIfCancelled()
    if !pending.isEmpty {
      let real = pending.count
      var chunk = pending
      chunk.append(contentsOf: [Float](repeating: 0, count: Self.chunkSize - real))
      pending.removeAll(keepingCapacity: true)
      try await classify(chunk, realCount: real)
    }
    if let start = openStart {
      if classified > start { closedSpans.append(start..<classified) }
      openStart = nil
    }
  }

  /// Live words (#4254 plan §18): the window's speech, whether speech is open and the classified
  /// end, from one snapshot. A window holds speech only where real (unpadded) speech falls
  /// inside it. The remnant of speech that began before the window, with less than one padding
  /// length (100 ms) of it inside, is the scrolled-out end of words already decoded, not
  /// speech to decode again: alone, Whisper turns such a sliver into "Thank you." (#4254 c3.1
  /// real-model gate). Speech that starts inside the window always counts.
  public func liveSpeech(in window: Range<Int>) -> MeetingLiveSpeech {
    var raw = closedSpans
    if let start = openStart, classified > start { raw.append(start..<classified) }
    let pad = AudioConstants.speechPaddingSamples
    raw.removeAll { span in
      guard span.overlaps(window) else { return true }
      let isRemnant = span.lowerBound < window.lowerBound
      return isRemnant && span.upperBound - window.lowerBound < pad
    }
    return MeetingLiveSpeech(
      speech: Self.padded(raw, within: window), speechOpen: openStart != nil,
      classifiedEnd: classified)
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
      try Task.checkCancellation()
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
      // The vendor's model call has no cancellation check of its own: report it here, after
      // the state moved on (the detector is stopped, so that state is never used again).
      try Task.checkCancellation()
    } catch is CancellationError {
      failed = true
      throw CancellationError()
    } catch {
      failed = true
      throw error
    }
  }

  /// A cancelled call is cancellation even when it would only buffer, and stops the detector
  /// like any other cancellation.
  private func stopIfCancelled() throws {
    guard Task.isCancelled else { return }
    failed = true
    throw CancellationError()
  }

  // MARK: - Ordering

  private func acquire() async {
    guard busy else {
      busy = true
      return
    }
    // Ownership is handed over by `release`, so `busy` stays true for the waiter.
    await withCheckedContinuation {
      waiters.append($0)
      onWait?()
    }
  }

  private func release() {
    if waiters.isEmpty {
      busy = false
    } else {
      waiters.removeFirst().resume()
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
