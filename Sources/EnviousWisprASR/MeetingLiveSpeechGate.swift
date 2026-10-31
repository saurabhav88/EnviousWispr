import EnviousWisprAudio

/// The live detector a meeting transcript session feeds (#4254 plan §16.2):
/// `MeetingSpeechDetector` in the app, a fake in tests.
package protocol LiveSpeechDetecting: Sendable {
  func append(_ samples: [Float]) async throws
  func window(_ window: Range<Int>) async -> MeetingSpeechWindow
  func prune(before sample: Int) async
  var classifiedSamples: Int { get async }
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
  /// Speech: decode from `from` samples into the window (leading silence trimmed; the
  /// detector's speech padding is already in it).
  case speech(from: Int)
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

  /// What `window` (absolute) holds so far.
  nonisolated(nonsending) func classify(_ window: Range<Int>) async -> MeetingLiveWindow {
    guard let detector else { return .raw }
    switch await detector.window(window) {
    case .speech(let ranges):
      return .speech(
        from: max(0, (ranges.first?.lowerBound ?? window.lowerBound) - window.lowerBound))
    case .silent:
      return .silent(through: window.upperBound)
    case .unknown:
      // The classified part holds no speech; a partial chunk at the end waits for more audio
      // and stays unknown, so only the classified part counts as processed.
      let classified = min(window.upperBound, await detector.classifiedSamples)
      return classified > window.lowerBound ? .silent(through: classified) : .pending
    }
  }

  /// Drops detected ranges no window from `sample` on can reach.
  nonisolated(nonsending) func prune(before sample: Int) async {
    await detector?.prune(before: sample)
  }
}
