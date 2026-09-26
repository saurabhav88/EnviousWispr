import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation
import os

/// #3105: Judge 1 (the correction classifier) defects that reach Sentry. Our own
/// shipped model failing is a defect (sentry-operations.md RULE:
/// sentry-for-bugs-posthog-for-behaviour); a busy-Mac deadline or a watcher that
/// lost the text is behaviour and stays a PostHog count (`learn_judged`,
/// `learn_observation_ended`). Never text: a closed kind and cause, the judge
/// revision, the arm and the macOS major.
enum LearnJudgeFailure: Error, Equatable, Sendable, CaseIterable {
  /// The admitted judge's files could not be loaded (`CoreMLCorrectionJudge.LoadFailure`).
  case modelLoadFailed
  /// A prediction came back unusable (`CoreMLCorrectionJudge.MalformedCause`).
  case outputMalformed
  /// The request the watcher built was refused (`CorrectionJudgeRequestError`).
  case requestBuildFailed
}

extension LearnJudgeFailure: StableSentryErrorIdentity {
  var sentryFingerprintDescriptor: String {
    switch self {
    case .modelLoadFailed: "LearnJudgeFailure#model_load_failed"
    case .outputMalformed: "LearnJudgeFailure#output_malformed"
    case .requestBuildFailed: "LearnJudgeFailure#request_build_failed"
    }
  }

  var sentrySemanticID: String {
    switch self {
    case .modelLoadFailed: "learn_judge.model_load_failed"
    case .outputMalformed: "learn_judge.output_malformed"
    case .requestBuildFailed: "learn_judge.request_build_failed"
    }
  }
}

/// Reports each `LearnJudgeFailure` kind once per process. The latch belongs to
/// the reporter, so a test's reporter never shares state with production's.
final class LearnJudgeFailureReporter: Sendable {
  typealias Capture = @Sendable (LearnJudgeFailure, _ cause: String, _ extra: [String: String]) ->
    Void

  static let shared = LearnJudgeFailureReporter()

  private let reported = OSAllocatedUnfairLock<Set<LearnJudgeFailure>>(initialState: [])
  private let capture: Capture
  private let osMajor: Int

  init(
    osMajor: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
    capture: @escaping Capture = LearnJudgeFailureReporter.sentry
  ) {
    self.osMajor = osMajor
    self.capture = capture
  }

  /// `cause` is a closed snake_case token from the failing layer's own enum.
  /// Returns whether this call reported (the first of its kind this process).
  @discardableResult
  func report(_ failure: LearnJudgeFailure, cause: String, arm: String, judgeRevision: String?)
    -> Bool
  {
    let first = reported.withLock { $0.insert(failure).inserted }
    guard first else { return false }
    var extra = [
      "kind": failure.sentrySemanticID, "cause": cause, "arm": arm, "os_major": String(osMajor),
    ]
    if let judgeRevision { extra["judge_revision"] = judgeRevision }
    capture(failure, cause, extra)
    return true
  }

  static let sentryStage = "learn_from_edits"

  /// `captureError` is main-actor isolated; the malformed observer runs on the
  /// Core ML judge's actor, so the capture hops. The latch already decided.
  static let sentry: Capture = { failure, cause, extra in
    Task { @MainActor in
      SentryBreadcrumb.captureError(
        failure, category: .learnJudgeFailure, stage: sentryStage, extra: extra,
        fingerprintDetail: cause)
    }
  }
}

extension LearnJudgeFailureReporter {
  /// The Core ML judge's load threw. A `LoadFailure` names its closed cause;
  /// anything else is `other` (its message can carry a path, so it stays in the log).
  func reportLoadFailure(_ error: any Error, judgeRevision: String?) {
    let cause = (error as? CoreMLCorrectionJudge.LoadFailure)?.causeCode ?? "other"
    report(.modelLoadFailed, cause: cause, arm: "classifier", judgeRevision: judgeRevision)
  }

  /// The observer a loaded Core ML judge calls on each malformed prediction.
  static func malformedObserver(
    judgeRevision: String?, reporter: LearnJudgeFailureReporter = .shared
  ) -> @Sendable (CoreMLCorrectionJudge.MalformedCause) -> Void {
    { cause in
      reporter.report(
        .outputMalformed, cause: cause.rawValue, arm: "classifier", judgeRevision: judgeRevision)
    }
  }
}
