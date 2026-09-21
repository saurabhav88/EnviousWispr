import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprServices

/// #2809 — the bucketing rules `TelemetryService.trackFileImportSpeakers` applies before
/// anything reaches PostHog. What fails when these fail: a dashboard reads a speaker count
/// that never happened, or "coverage" flips between full/partial/none for reasons that have
/// nothing to do with what the engine actually returned.
@Suite("File import speaker telemetry buckets (#2809)", .tags(.observabilityContract))
@MainActor
struct FileImportSpeakerTelemetryBucketTests {

  @Test("speaker_bucket is present for single/labeled and nil for failed/timedOut")
  func speakerBucketPresenceMatchesOutcome() {
    #expect(
      TelemetryService.fileImportSpeakerBucket(.single(segments: [])) == "1")
    #expect(
      TelemetryService.fileImportSpeakerBucket(.labeled(count: 2, segments: [])) == "2")
    #expect(
      TelemetryService.fileImportSpeakerBucket(.failed(.modelsUnavailable)) == nil)
    #expect(TelemetryService.fileImportSpeakerBucket(.timedOut(afterMs: 100)) == nil)
  }

  @Test("speaker_bucket buckets 3-4 together and 5+ together")
  func speakerBucketGroupsHigherCounts() {
    #expect(TelemetryService.fileImportSpeakerBucket(.labeled(count: 3, segments: [])) == "3-4")
    #expect(TelemetryService.fileImportSpeakerBucket(.labeled(count: 4, segments: [])) == "3-4")
    #expect(TelemetryService.fileImportSpeakerBucket(.labeled(count: 5, segments: [])) == "5+")
    #expect(TelemetryService.fileImportSpeakerBucket(.labeled(count: 22, segments: [])) == "5+")
  }

  @Test("word_timing_coverage_bucket: nil, zero-total, and zero-timed all read as none")
  func coverageBucketNoneCases() {
    #expect(TelemetryService.wordTimingCoverageBucket(nil) == "none")
    #expect(
      TelemetryService.wordTimingCoverageBucket(ASRWordTimingCoverage(timed: 0, total: 0))
        == "none")
    #expect(
      TelemetryService.wordTimingCoverageBucket(ASRWordTimingCoverage(timed: 0, total: 10))
        == "none")
  }

  @Test("word_timing_coverage_bucket: full is timed >= total, a caller bug included")
  func coverageBucketFullAndPartial() {
    #expect(
      TelemetryService.wordTimingCoverageBucket(ASRWordTimingCoverage(timed: 10, total: 10))
        == "full")
    #expect(
      TelemetryService.wordTimingCoverageBucket(ASRWordTimingCoverage(timed: 5, total: 10))
        == "partial")
    // A caller bug (timed > total) still resolves to a real bucket rather than crashing or
    // producing an out-of-domain string — `>=` reads this as "full", the least-wrong answer
    // for data that should never occur (the mapper's own contract guarantees timed <= total).
    #expect(
      TelemetryService.wordTimingCoverageBucket(ASRWordTimingCoverage(timed: 11, total: 10))
        == "full")
  }

  @Test("duration_bucket covers the full range from seconds to multi-hour files")
  func durationBucketRanges() {
    #expect(TelemetryService.fileImportDurationBucket(30) == "<1min")
    #expect(TelemetryService.fileImportDurationBucket(120) == "1-5min")
    #expect(TelemetryService.fileImportDurationBucket(600) == "5-15min")
    #expect(TelemetryService.fileImportDurationBucket(1200) == "15-30min")
    #expect(TelemetryService.fileImportDurationBucket(2400) == "30-60min")
    #expect(TelemetryService.fileImportDurationBucket(10800) == "60min+")  // 3 hours
  }

  @Test("outcome strings match the four SpeakerAnalysis cases exactly")
  func outcomeStrings() {
    #expect(TelemetryService.fileImportSpeakerOutcome(.single(segments: [])) == "single")
    #expect(
      TelemetryService.fileImportSpeakerOutcome(.labeled(count: 2, segments: [])) == "labeled")
    #expect(TelemetryService.fileImportSpeakerOutcome(.failed(.cancelled)) == "failed")
    #expect(TelemetryService.fileImportSpeakerOutcome(.timedOut(afterMs: 100)) == "timed_out")
  }

  // MARK: - file_import_completed (#3069)

  @Test("polish outcome distinguishes skipped (never asked) from failed (asked, got nothing)")
  func polishOutcomeSkippedVersusFailed() {
    #expect(
      TelemetryService.fileImportPolishOutcome(attemptedParts: 0, polishedParts: 0) == .skipped)
    #expect(
      TelemetryService.fileImportPolishOutcome(attemptedParts: 3, polishedParts: 0) == .failed)
    #expect(
      TelemetryService.fileImportPolishOutcome(attemptedParts: 3, polishedParts: 3) == .success)
    #expect(
      TelemetryService.fileImportPolishOutcome(attemptedParts: 3, polishedParts: 1) == .partial)
  }

  // `testEventHook`/`CapturedTelemetryEvent` are DEBUG-only (CI also compiles tests in
  // Release); wrap every test that reads them, matching `OllamaReadinessGateTests`.
  #if DEBUG
    /// A synchronous, same-actor recorder for a single hook firing — the call under test never
    /// crosses a suspension point, so unlike `TelemetryEventWaiter` (used where the emission
    /// happens on a detached task) this only needs `MainActor.assumeIsolated` to satisfy Swift 6
    /// strict concurrency on the `@Sendable` closure type, never an async wait.
    @MainActor
    private final class SyncEventRecorder {
      var event: CapturedTelemetryEvent?
    }

    @Test("trackFileImportCompleted emits outcome, backend and duration bucket every time")
    func trackFileImportCompletedAlwaysEmitsCoreFields() {
      let recorder = SyncEventRecorder()
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated { recorder.event = event }
      }
      defer { TelemetryService.shared.testEventHook = nil }
      TelemetryService.shared.trackFileImportCompleted(
        outcome: .asrFailed, asrBackend: .parakeet, durationSeconds: 120)
      #expect(recorder.event?.name == "file_import_completed")
      #expect(recorder.event?.stringProps["outcome"] == "asr_failed")
      #expect(recorder.event?.stringProps["asr_backend"] == "parakeet")
      #expect(recorder.event?.stringProps["duration_bucket"] == "1-5min")
      #expect(recorder.event?.stringProps["polish_outcome"] == nil)
      #expect(recorder.event?.stringProps["polish_provider"] == nil)
    }

    @Test("trackFileImportCompleted omits polish fields when no provider was configured")
    func trackFileImportCompletedOmitsPolishFieldsForNoneProvider() {
      let recorder = SyncEventRecorder()
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated { recorder.event = event }
      }
      defer { TelemetryService.shared.testEventHook = nil }
      TelemetryService.shared.trackFileImportCompleted(
        outcome: .success, asrBackend: .whisperKit, durationSeconds: 30,
        asrOutcome: .success, polishOutcome: .skipped, polishProvider: .none,
        polishModel: "should-not-appear")
      #expect(recorder.event?.stringProps["polish_outcome"] == "skipped")
      #expect(recorder.event?.stringProps["polish_provider"] == nil)
      #expect(recorder.event?.stringProps["polish_model"] == nil)
    }

    @Test("trackFileImportCompleted includes provider and model when a real polisher ran")
    func trackFileImportCompletedIncludesProviderAndModel() {
      let recorder = SyncEventRecorder()
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated { recorder.event = event }
      }
      defer { TelemetryService.shared.testEventHook = nil }
      TelemetryService.shared.trackFileImportCompleted(
        outcome: .success, asrBackend: .parakeet, durationSeconds: 30,
        asrOutcome: .success, polishOutcome: .success, polishProvider: .ollama,
        polishModel: "llama3.1")
      #expect(recorder.event?.stringProps["polish_provider"] == "ollama")
      #expect(recorder.event?.stringProps["polish_model"] == "llama3.1")
    }
  #endif
}
