import EnviousWisprAudio
import EnviousWisprCore
@preconcurrency import FluidAudio
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// A one-shot "it started" signal, so a test can wait for a fake worker to actually be
/// running before cancelling it, instead of guessing a fixed sleep.
private actor StartedSignal {
  private var started = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func markStarted() {
    started = true
    for waiter in waiters { waiter.resume() }
    waiters = []
  }

  func wait() async {
    if started { return }
    await withCheckedContinuation { waiters.append($0) }
  }
}

private enum SpeakerLabelerRealFixture {
  static let audioURL = RepoRoot.sourceURL("Tests/Fixtures/speaker-diarization/two-voice-30s.wav")
  static var modelsInstalled: Bool {
    FileManager.default.fileExists(
      atPath: RepoRoot.sourceURL("Sources/EnviousWispr/Resources/SpeakerModels/FBank.mlmodelc")
        .path)
  }
}

/// #2809: `SpeakerLabeler` is the one owner of the deadline, cancellation forwarding, and
/// worker joining for the dormant speaker step. What fails when these fail: a stopped
/// import holds the shared engine for up to a worker's own runtime instead of releasing it
/// promptly, or a slow file silently runs forever instead of reporting `.timedOut`.
@Suite("SpeakerLabeler", .tags(.productOutcome))
struct SpeakerLabelerTests {

  @Test("deadline is max(20s, 0.5s per minute of audio)")
  func deadlineFormula() {
    #expect(SpeakerLabeler.deadlineSeconds(forDurationSeconds: 0) == 20)
    #expect(SpeakerLabeler.deadlineSeconds(forDurationSeconds: 60) == 20)  // 1 min -> 0.5s, floored to 20
    #expect(SpeakerLabeler.deadlineSeconds(forDurationSeconds: 60 * 100) == 50)  // 100 min -> 50s
  }

  @Test("a deadline exceeded returns .timedOut and joins the worker before returning")
  func deadlineExceededReturnsTimedOut() async {
    final class JoinFlag: @unchecked Sendable {
      var joined = false
    }
    let flag = JoinFlag()
    let labeler = SpeakerLabeler(
      deadlineSecondsOverride: 0.05,
      analysisTask: { _ in
        Task<[SpeakerSegment], Error> {
          defer { flag.joined = true }
          // Outlives the 0.05s deadline by a wide margin; must be cancelled and joined,
          // never left running. settle: simulates a slow/hung worker, never actually elapses.
          try await Task.sleep(nanoseconds: 5_000_000_000)
          return []
        }
      })
    let outcome = await labeler.run(samples: [], durationSeconds: 0)
    guard case .timedOut(let afterMs) = outcome else {
      Issue.record("expected .timedOut, got \(outcome)")
      return
    }
    #expect(afterMs == 50)
    #expect(flag.joined, "the worker must have exited (via cancellation) before run() returned")
  }

  @Test(
    "a missing bundled model reports .failed(.modelsUnavailable), not the generic analyzerThrew")
  func modelsUnavailableIsDistinguishedFromOtherThrows() async {
    let labeler = SpeakerLabeler(
      deadlineSecondsOverride: 5,
      analysisTask: { _ in
        Task<[SpeakerSegment], Error> {
          throw BundledSpeakerModelLoader.LoadError.resourceNotFound("Segmentation")
        }
      })
    let outcome = await labeler.run(samples: [], durationSeconds: 0)
    guard case .failed(.modelsUnavailable) = outcome else {
      Issue.record("expected .failed(.modelsUnavailable), got \(outcome)")
      return
    }
  }

  @Test(
    "cancelling mid-analysis against the REAL bundled models and a real recording exits promptly",
    .enabled(if: SpeakerLabelerRealFixture.modelsInstalled),
    .tags(.realBoundary)
  )
  func realCancellationExitsPromptly() async throws {
    let resourcesRoot = RepoRoot.sourceURL("Sources/EnviousWispr/Resources")
    let bundleRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("SpeakerLabelerRealBoundary-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: bundleRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: bundleRoot) }
    for name in ["Segmentation", "FBank", "Embedding", "PldaRho"] {
      try FileManager.default.createSymbolicLink(
        at: bundleRoot.appendingPathComponent("\(name).mlmodelc"),
        withDestinationURL: resourcesRoot.appendingPathComponent("SpeakerModels/\(name).mlmodelc"))
    }
    try FileManager.default.createSymbolicLink(
      at: bundleRoot.appendingPathComponent("speaker-plda-parameters.json"),
      withDestinationURL: resourcesRoot.appendingPathComponent("speaker-plda-parameters.json"))
    let fixtureBundle = try #require(Bundle(path: bundleRoot.path))

    let startedSignal = StartedSignal()
    let labeler = SpeakerLabeler(
      deadlineSecondsOverride: 30,
      analysisTask: { samples in
        Task<[SpeakerSegment], Error> {
          let models = try BundledSpeakerModelLoader.load(in: fixtureBundle)
          let analyzer = OfflineSpeakerAnalyzer()
          analyzer.initialize(models: models)
          return try await analyzer.analyze(samples: samples, sampleRate: 16000) { _, _ in
            Task { await startedSignal.markStarted() }
          }
        }
      })
    let samples = try AudioConverter().resampleAudioFile(
      path: SpeakerLabelerRealFixture.audioURL.path)

    let clock = ContinuousClock()
    let runTask = Task { await labeler.run(samples: samples, durationSeconds: 28) }
    await startedSignal.wait()
    // Measured from the cancel call itself, not from before the task even started — this
    // fixture's real analysis has no artificial delay (it finishes in ~1-2s on its own), so
    // an elapsed time measured from task creation would pass even if cancellation did
    // nothing at all. The `.failed(.cancelled)` assertion below is what actually proves
    // cancellation was honored; this bound only catches a genuine hang.
    let cancelledAt = clock.now
    runTask.cancel()
    let outcome = await runTask.value
    let elapsed = clock.now - cancelledAt

    guard case .failed(.cancelled) = outcome else {
      Issue.record("expected .failed(.cancelled), got \(outcome)")
      return
    }
    // Bounded generously (30s, against ~1-2s in isolation) so contention from the full test
    // suite running many real CoreML models concurrently cannot make this flake; a genuine
    // "cancellation does nothing" regression would still complete the ~1-2s analysis and
    // pass this bound too — the outcome check above is the real proof, this is a hang guard.
    #expect(
      elapsed < .seconds(30),
      "cancellation took \(elapsed) to exit — the worker may be hung")
  }

  @Test("an analyzer that throws returns .failed(.analyzerThrew), never crashes")
  func analyzerThrowReturnsFailed() async {
    struct Boom: Error {}
    let labeler = SpeakerLabeler(
      deadlineSecondsOverride: 5,
      analysisTask: { _ in Task<[SpeakerSegment], Error> { throw Boom() } })
    let outcome = await labeler.run(samples: [], durationSeconds: 0)
    guard case .failed(.analyzerThrew) = outcome else {
      Issue.record("expected .failed(.analyzerThrew), got \(outcome)")
      return
    }
  }

  @Test(
    "an analyzer that finishes with zero segments reports .failed(.noSpeakerSegments), not .analyzerThrew"
  )
  func zeroSegmentsReportsNoSpeakerSegments() async {
    let labeler = SpeakerLabeler(
      deadlineSecondsOverride: 5,
      analysisTask: { _ in Task<[SpeakerSegment], Error> { [] } })
    let outcome = await labeler.run(samples: [], durationSeconds: 0)
    guard case .failed(.noSpeakerSegments) = outcome else {
      Issue.record("expected .failed(.noSpeakerSegments), got \(outcome)")
      return
    }
  }

  @Test("a single detected speaker reports .single, not .labeled(count: 1)")
  func singleSpeakerReportsSingle() async {
    let segment = SpeakerSegment(speakerId: "0", startMs: 0, endMs: 1000, quality: 1)
    let labeler = SpeakerLabeler(
      deadlineSecondsOverride: 5,
      analysisTask: { _ in Task<[SpeakerSegment], Error> { [segment] } })
    let outcome = await labeler.run(samples: [], durationSeconds: 0)
    guard case .single(let segments) = outcome else {
      Issue.record("expected .single, got \(outcome)")
      return
    }
    #expect(segments == [segment])
  }

  @Test("two detected speakers report .labeled(count: 2, ...)")
  func twoSpeakersReportsLabeled() async {
    let segments = [
      SpeakerSegment(speakerId: "0", startMs: 0, endMs: 500, quality: 1),
      SpeakerSegment(speakerId: "1", startMs: 500, endMs: 1000, quality: 1),
    ]
    let labeler = SpeakerLabeler(
      deadlineSecondsOverride: 5,
      analysisTask: { _ in Task<[SpeakerSegment], Error> { segments } })
    let outcome = await labeler.run(samples: [], durationSeconds: 0)
    guard case .labeled(let count, let returnedSegments) = outcome else {
      Issue.record("expected .labeled, got \(outcome)")
      return
    }
    #expect(count == 2)
    #expect(returnedSegments == segments)
  }

  @Test("external cancellation returns .failed(.cancelled) and joins the worker promptly")
  func externalCancellationReturnsFailedCancelled() async {
    final class JoinFlag: @unchecked Sendable {
      var joined = false
    }
    let flag = JoinFlag()
    let startedSignal = StartedSignal()
    let labeler = SpeakerLabeler(
      deadlineSecondsOverride: 30,
      analysisTask: { _ in
        Task<[SpeakerSegment], Error> {
          await startedSignal.markStarted()
          defer { flag.joined = true }
          // settle: simulates a slow worker, cancelled well before this would elapse.
          try await Task.sleep(nanoseconds: 30_000_000_000)
          return []
        }
      })
    let runTask = Task { await labeler.run(samples: [], durationSeconds: 0) }
    await startedSignal.wait()
    runTask.cancel()
    let outcome = await runTask.value
    guard case .failed(.cancelled) = outcome else {
      Issue.record("expected .failed(.cancelled), got \(outcome)")
      return
    }
    #expect(flag.joined, "the worker must have exited before run() returned")
  }
}
