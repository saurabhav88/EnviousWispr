import EnviousWisprAudio

/// The live detector a meeting transcript session feeds (#4254 plan §16.2):
/// `MeetingSpeechDetector` in the app, a fake in tests.
package protocol LiveSpeechDetecting: Sendable {
  func append(_ samples: [Float]) async throws
  func liveSpeech(in window: Range<Int>) async -> MeetingLiveSpeech
  func prune(before sample: Int) async
}

extension MeetingSpeechDetector: LiveSpeechDetecting {}

/// The app's live detector for a meeting transcript session: the pinned bundled model.
package func meetingLiveSpeechDetector() -> any LiveSpeechDetecting { MeetingSpeechDetector() }

/// How one meeting live window is decoded (#4254 plan §16.2, §16.6).
enum MeetingLiveWindow: Equatable {
  /// Every classified sample of the window up to `through` (absolute) is silence: no native
  /// decode, and the processed-audio mark moves to `through`.
  case silent(through: Int)
  /// Nothing in the window is classified yet: no decode this cycle, no mark change.
  case pending
  /// Speech: decode the window from `from` to `to` (window-relative). Leading silence is
  /// trimmed (the detector's padding is already in `from`); `to` is the padded end of the last
  /// speech when that speech is closed and only classified silence follows it, else the
  /// window end (plan §18 c3.1).
  case speech(from: Int, to: Int)
  /// Detection is off for this session: today's untrimmed decode.
  case raw
}

/// One meeting transcript session's speech detection: one continuous detector fed each
/// captured sample exactly once by absolute position, independently of the overlapping decode
/// windows. Owned by the rolling session's actor; created per run, released with it.
///
/// A detector error, or audio dropped before it was fed, turns detection off for the rest of
/// the session: recurrent state never resumes across audio it did not process, and later
/// windows take today's raw route. Its methods run on the caller's actor
/// (`nonisolated(nonsending)`): the gate never leaves the session.
final class MeetingLiveSpeechGate {
  private var detector: (any LiveSpeechDetecting)?
  /// Absolute samples fed so far.
  private(set) var fed = 0

  init(detector: any LiveSpeechDetecting) {
    self.detector = detector
  }

  var isDegraded: Bool { detector == nil }

  #if DEBUG
    /// The last classified end read from the detector; kept when detection turns off.
    private(set) var lastClassified = 0

    /// #4254 UAT evidence: samples the real detector has classified so far.
    nonisolated(nonsending) func classifiedEnd() async -> Int {
      guard let detector else { return lastClassified }
      lastClassified = await detector.liveSpeech(in: fed..<fed).classifiedEnd
      return lastClassified
    }
  #endif

  /// Feeds the samples captured since the last call. `samples` holds the last `samples.count`
  /// of `count` captured samples. Returns true when detection turned off in this call; throws
  /// only `CancellationError`.
  nonisolated(nonsending) func feed(_ samples: [Float], count: Int) async throws -> Bool {
    guard let detector, count > fed else { return false }
    let first = count - samples.count
    guard fed >= first else {
      // Audio the detector never saw is gone: its state cannot continue past the gap.
      self.detector = nil
      return true
    }
    do {
      try await detector.append(Array(samples[(fed - first)..<(count - first)]))
      fed = count
      return false
    } catch is CancellationError {
      self.detector = nil
      throw CancellationError()
    } catch {
      self.detector = nil
      return true
    }
  }

  /// What `window` (absolute) holds so far, from one detector snapshot.
  ///
  /// `holdingTo` (absolute): the end of the input that produced the words still in dispute. A
  /// closed slice never ends before it, so the decode compared for agreement hears at least
  /// what the disputed decode heard (#4254 §16.5: an earlier end changed the disputed words of
  /// overlapping voices, and the origin move then released them). An end not yet classified
  /// waits (`.pending`).
  nonisolated(nonsending) func classify(_ window: Range<Int>, holdingTo: Int? = nil) async
    -> MeetingLiveWindow
  {
    guard let detector else { return .raw }
    let live = await detector.liveSpeech(in: window)
    #if DEBUG
      lastClassified = live.classifiedEnd
    #endif
    guard let first = live.speech.first, let last = live.speech.last else {
      // The classified part holds no speech. A partial chunk at the end waits for more audio
      // and stays unknown, so only the classified part counts as processed.
      let classified = min(window.upperBound, live.classifiedEnd)
      return classified > window.lowerBound ? .silent(through: classified) : .pending
    }
    let from = max(0, first.lowerBound - window.lowerBound)
    // A closed last speech ends the slice at its padding (never past what was classified);
    // open speech, or speech reaching the window end, keeps the window end.
    let end = min(last.upperBound, live.classifiedEnd)
    guard !live.speechOpen && end < window.upperBound && end > first.lowerBound else {
      return .speech(from: from, to: window.count)
    }
    guard let holdingTo, holdingTo > end else { return .speech(from: from, to: end - window.lowerBound) }
    guard holdingTo <= live.classifiedEnd else { return .pending }
    return .speech(from: from, to: min(holdingTo, window.upperBound) - window.lowerBound)
  }

  /// Drops detected ranges no window from `sample` on can reach.
  nonisolated(nonsending) func prune(before sample: Int) async {
    await detector?.prune(before: sample)
  }
}
