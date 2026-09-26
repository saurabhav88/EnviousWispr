import EnviousWisprCore
import EnviousWisprLLM
import Foundation
import Testing
import os

@testable import EnviousWisprAppKit
@testable import EnviousWisprServices

/// #3105: Judge 1 defects reach Sentry once per process per kind, with a closed
/// cause and no text.
@Suite("Judge 1 failure reports (#3105)", .tags(.observabilityContract))
struct LearnJudgeFailureReporterTests {
  private final class Captured: Sendable {
    let calls = OSAllocatedUnfairLock<[(LearnJudgeFailure, String, [String: String])]>(
      initialState: [])
  }

  private func reporter() -> (LearnJudgeFailureReporter, Captured) {
    let captured = Captured()
    let reporter = LearnJudgeFailureReporter(osMajor: 27) { failure, cause, extra in
      captured.calls.withLock { $0.append((failure, cause, extra)) }
    }
    return (reporter, captured)
  }

  @Test("each kind reports once per process; a second kind still reports")
  func oncePerKind() {
    let (reporter, captured) = reporter()
    #expect(
      reporter.report(
        .outputMalformed, cause: "missing_logits", arm: "classifier", judgeRevision: "r1"))
    #expect(
      !reporter.report(
        .outputMalformed, cause: "prediction_threw", arm: "classifier", judgeRevision: "r1"))
    #expect(
      reporter.report(
        .modelLoadFailed, cause: "model_load_failed", arm: "classifier", judgeRevision: "r1"))
    let kinds = captured.calls.withLock { $0.map(\.0) }
    #expect(kinds == [.outputMalformed, .modelLoadFailed])
  }

  @Test("the payload names kind, closed cause, arm, revision and macOS, and nothing else")
  func payloadIsClosed() throws {
    let (reporter, captured) = reporter()
    reporter.reportLoadFailure(
      CoreMLCorrectionJudge.LoadFailure.missingFile("/Users/someone/Secret Folder/model"),
      judgeRevision: "3b376fbc-ec68ad6e")
    let call = try #require(captured.calls.withLock { $0.first })
    #expect(call.0 == .modelLoadFailed)
    #expect(call.1 == "missing_file")
    #expect(
      call.2 == [
        "kind": "learn_judge.model_load_failed", "cause": "missing_file", "arm": "classifier",
        "os_major": "27", "judge_revision": "3b376fbc-ec68ad6e",
      ])
    #expect(!call.2.values.contains { $0.contains("/") })
  }

  @Test("a load error that is not a typed load failure reports cause other")
  func untypedLoadError() throws {
    struct Opaque: Error {}
    let (reporter, captured) = reporter()
    reporter.reportLoadFailure(Opaque(), judgeRevision: nil)
    let call = try #require(captured.calls.withLock { $0.first })
    #expect(call.1 == "other")
    #expect(call.2["judge_revision"] == nil)
  }

  @Test("the malformed observer reports the judge's own closed cause")
  func malformedObserver() throws {
    let (reporter, captured) = reporter()
    let observe = LearnJudgeFailureReporter.malformedObserver(
      judgeRevision: "r1", reporter: reporter)
    observe(.invalidProbability)
    let call = try #require(captured.calls.withLock { $0.first })
    #expect(call.0 == .outputMalformed)
    #expect(call.1 == "invalid_probability")
    #expect(
      Set(CoreMLCorrectionJudge.MalformedCause.allCases.map(\.rawValue))
        == ["missing_logits", "prediction_threw", "invalid_probability"])
  }

  @Test("request errors and load failures map to closed causes without their values")
  func causeCodes() {
    #expect(CorrectionJudgeRequestError.tooManyCandidates(9).causeCode == "too_many_candidates")
    #expect(CorrectionJudgeRequestError.contextTooLong(4096).causeCode == "context_too_long")
    #expect(CorrectionJudgeRequestError.unchangedRun(id: 2).causeCode == "unchanged_run")
    #expect(
      CoreMLCorrectionJudge.LoadFailure.manifestInvalid("bad json at /x").causeCode
        == "manifest_invalid")
    #expect(CoreMLCorrectionJudge.LoadFailure.modelIOMismatch.causeCode == "model_io_mismatch")
  }

  @MainActor
  @Test("the Sentry event carries the reporter's payload, groups by kind and cause, and holds no path or text")
  func eventGrouping() throws {
    // The same arguments `LearnJudgeFailureReporter.sentry` hands `captureError`, which builds
    // its event with `makeHandledErrorEvent`, including the audio-environment merge.
    let (reporter, captured) = reporter()
    reporter.reportLoadFailure(
      CoreMLCorrectionJudge.LoadFailure.identityMismatch("/Users/someone/Library/judge sha mismatch"),
      judgeRevision: "3b376fbc-ec68ad6e")
    let call = try #require(captured.calls.withLock { $0.first })
    // A deterministic audio environment, so the merged event's whole `extra` is known.
    let loaded = SentryBreadcrumb.withAudioEnvironmentProvider({ ["snapshot_status": "fresh"] }) {
      SentryBreadcrumb.makeHandledErrorEvent(
        call.0, category: .learnJudgeFailure, stage: LearnJudgeFailureReporter.sentryStage,
        extra: call.2, fingerprintDetail: call.1, environment: "production")
    }
    let extra = try #require(loaded.extra)
    #expect(
      Set(extra.keys)
        == ["kind", "cause", "arm", "os_major", "judge_revision", "audio_environment"])
    #expect(extra["kind"] as? String == "learn_judge.model_load_failed")
    #expect(extra["cause"] as? String == "identity_mismatch")
    #expect(extra["arm"] as? String == "classifier")
    #expect(extra["os_major"] as? String == "27")
    #expect(extra["judge_revision"] as? String == "3b376fbc-ec68ad6e")
    let environment = try #require(extra["audio_environment"] as? [String: Any])
    #expect(Set(environment.keys) == ["snapshot_status"])
    #expect(environment["snapshot_status"] as? String == "fresh")
    for (key, value) in extra {
      #expect(!"\(value)".contains("/Users"), "\(key) carries a path")
      #expect(!"\(value)".contains("sha mismatch"), "\(key) carries the error's text")
    }
    #expect(loaded.tags?["pipeline.stage"] == "learn_from_edits")
    let event = SentryBreadcrumb.makeHandledErrorEvent(
      LearnJudgeFailure.outputMalformed, category: .learnJudgeFailure,
      stage: LearnJudgeFailureReporter.sentryStage,
      extra: ["cause": "missing_logits"], fingerprintDetail: "missing_logits",
      environment: "production")
    #expect(event.message?.formatted == "learn_judge_failure: LearnJudgeFailure#output_malformed")
    #expect(
      event.fingerprint
        == [
          "handled_error", "learn_judge_failure", "LearnJudgeFailure#output_malformed",
          "missing_logits", "production",
        ])
    #expect(event.tags?["error.identity"] == "learn_judge.output_malformed")
    #expect(
      LearnJudgeFailure.allCases.map(\.sentryFingerprintDescriptor) == [
        "LearnJudgeFailure#model_load_failed", "LearnJudgeFailure#output_malformed",
        "LearnJudgeFailure#request_build_failed",
      ])
  }
}
