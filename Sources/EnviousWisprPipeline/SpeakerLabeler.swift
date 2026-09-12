import EnviousWisprAudio
import EnviousWisprCore
import Foundation

/// The dormant, phase-2 speaker step on a file import (#2809 addendum §3 B3). The ONE
/// owner of the deadline constant, cancellation forwarding, and worker joining: `run`
/// never returns while its analysis task is still alive, on any exit path.
///
/// Loads the bundled models itself on every call rather than caching a loaded instance —
/// file imports are infrequent enough that a fresh, cheap (~tens of milliseconds) local
/// load costs nothing next to the analysis itself, and it keeps this type stateless.
public struct SpeakerLabeler: Sendable {

  /// `max(20 s, 0.5 s per minute of audio)`. The spike's slowest real run was 0.22 s/min
  /// (187 minutes in 41 s); this is roughly 2x headroom on the machine that measured it.
  /// The supported-floor machine (M1, 8 GB) is unmeasured — see addendum §14 item 2.
  static let minimumDeadlineSeconds: Double = 20
  static let secondsPerMinuteOfAudio: Double = 0.5

  static func deadlineSeconds(forDurationSeconds durationSeconds: Double) -> Double {
    max(minimumDeadlineSeconds, secondsPerMinuteOfAudio * (durationSeconds / 60))
  }

  private struct DeadlineExceeded: Error {}

  /// `nil` in production: the deadline is always computed from the real audio duration.
  /// A test overrides it to exercise the deadline-exceeded branch in milliseconds rather
  /// than the real 20-second floor.
  private let deadlineSecondsOverride: Double?
  private let makeAnalysisTask: @Sendable ([Float]) -> Task<[SpeakerSegment], Error>

  public init() {
    deadlineSecondsOverride = nil
    makeAnalysisTask = { samples in
      Task<[SpeakerSegment], Error> {
        // A Stop landing in the gap between `run()` creating this task and its
        // first line running would otherwise still pay for a full model load
        // (tens of ms) before anything notices. Second-pass review.
        try Task.checkCancellation()
        let models = try BundledSpeakerModelLoader.load(in: .main)
        let analyzer = OfflineSpeakerAnalyzer()
        analyzer.initialize(models: models)
        return try await analyzer.analyze(samples: samples, sampleRate: 16000) { _, _ in }
      }
    }
  }

  /// Test-only seam: injects the analysis work and a deadline, so the race/join logic is
  /// exercisable without a real model load or a real 20-second wait. `internal` — reached
  /// via `@testable import`, never a production construction site.
  init(
    deadlineSecondsOverride: Double,
    analysisTask makeAnalysisTask: @escaping @Sendable ([Float]) -> Task<[SpeakerSegment], Error>
  ) {
    self.deadlineSecondsOverride = deadlineSecondsOverride
    self.makeAnalysisTask = makeAnalysisTask
  }

  public func run(samples: [Float], durationSeconds: Double) async -> SpeakerAnalysis {
    // A caller that was already cancelled before reaching this call has no
    // reason to pay for a model load it will immediately throw away. Second-
    // pass review.
    guard !Task.isCancelled else { return .failed(.cancelled) }

    let deadlineSeconds =
      deadlineSecondsOverride ?? Self.deadlineSeconds(forDurationSeconds: durationSeconds)

    let analysisTask = makeAnalysisTask(samples)

    return await withTaskCancellationHandler {
      do {
        let segments = try await Self.racingDeadline(
          seconds: deadlineSeconds, analysisTask: analysisTask)
        // The race can only be decided AFTER `analysisTask` genuinely finished (see
        // `racingDeadline`), but it can finish with a real result even though THIS task
        // was separately cancelled in the meantime (cooperative cancellation lets work
        // that was already done stand). Check explicitly rather than let a stale success
        // leak past a cancellation the caller is relying on.
        try Task.checkCancellation()
        guard !segments.isEmpty else {
          // Zero segments is not "one speaker" — it is the analyzer finding nothing to
          // attribute, and reporting it as `.single` would corrupt `speaker_bucket`
          // telemetry with a count that never happened. A distinct case, not
          // `.analyzerThrew`: nothing threw, so that label would be a false cause
          // (found by second-pass review).
          return .failed(.noSpeakerSegments)
        }
        let distinctSpeakers = Set(segments.map(\.speakerId))
        if distinctSpeakers.count <= 1 {
          return .single(segments: segments)
        }
        return .labeled(count: distinctSpeakers.count, segments: segments)
      } catch is DeadlineExceeded {
        // `racingDeadline` already cancelled `analysisTask` and its own task group has
        // already awaited it to finish before returning here — this join is a cheap,
        // harmless confirmation, not a wait.
        _ = try? await analysisTask.value
        // A Stop can arrive WHILE this timed-out worker is being joined above. When it
        // did, report the cancellation the caller is relying on, not a timeout that is
        // no longer the reason this run is ending (found by Codex chunk-3 round 2).
        if Task.isCancelled { return .failed(.cancelled) }
        return .timedOut(afterMs: Int((deadlineSeconds * 1000).rounded()))
      } catch is CancellationError {
        analysisTask.cancel()
        _ = try? await analysisTask.value
        return .failed(.cancelled)
      } catch is BundledSpeakerModelLoader.LoadError {
        _ = try? await analysisTask.value
        // Same reasoning as the timeout branch: a cancellation racing a load failure
        // must not be reported as `.modelsUnavailable`.
        if Task.isCancelled { return .failed(.cancelled) }
        return .failed(.modelsUnavailable)
      } catch {
        _ = try? await analysisTask.value
        if Task.isCancelled { return .failed(.cancelled) }
        return .failed(.analyzerThrew(String(describing: error)))
      }
    } onCancel: {
      analysisTask.cancel()
    }
  }

  /// Races `analysisTask` against a wall-clock sleep, **deciding the race BEFORE either
  /// side is touched further** — `analysisTask.result` never throws (it wraps success or
  /// failure), and the sleep child returns a plain marker rather than throwing on elapse,
  /// so `group.next()` returns whichever side genuinely finished FIRST with no side effect
  /// from either child able to influence that outcome. Only once the winner is known does
  /// this function act: on a real finish, decode and return/rethrow its `Result`; on a
  /// timeout, cancel `analysisTask` and throw `DeadlineExceeded`.
  ///
  /// **Why the previous version was wrong, kept as the reason not to revert this:** it
  /// called `analysisTask.cancel()` INSIDE the sleep child before throwing, which can make
  /// the analysis child observe cancellation and finish (via `CancellationError`) fast
  /// enough to win `group.next()` over the sleep child's own throw — misclassifying a
  /// timeout as an external cancellation. Cancelling `analysisTask` only AFTER the race is
  /// decided removes that self-inflicted race entirely (found by Codex chunk-3 review).
  private static func racingDeadline(
    seconds: Double, analysisTask: Task<[SpeakerSegment], Error>
  ) async throws -> [SpeakerSegment] {
    enum RaceOutcome: Sendable {
      case finished(Result<[SpeakerSegment], Error>)
      case deadlineElapsed
    }
    return try await withThrowingTaskGroup(of: RaceOutcome.self) { group in
      group.addTask { .finished(await analysisTask.result) }
      group.addTask {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        return .deadlineElapsed
      }
      defer { group.cancelAll() }
      switch try await group.next()! {
      case .finished(let result):
        return try result.get()
      case .deadlineElapsed:
        analysisTask.cancel()
        throw DeadlineExceeded()
      }
    }
  }
}
