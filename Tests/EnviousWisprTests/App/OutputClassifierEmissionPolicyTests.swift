import EnviousWisprLLM
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #1452: `OutputClassifierEmissionPolicy.forOutcome` is the actual
/// alert-dedup contract — the outcome→emission decision `WisprBootstrapper`
/// executes. Exhaustively covers all 8 `OutputClassifierAttemptOutcome` cases
/// (#1226 added `.succeededViaFallback`/`.failedAfterFallback`, renamed
/// `.failedFirstTime` to `.failedNoRetry`) so a wrong `switch` arm (e.g.
/// alerting on a suppressed repeat) fails here instead of only being
/// discoverable by reading the switch statement.
@Suite("OutputClassifierEmissionPolicy.forOutcome")
struct OutputClassifierEmissionPolicyTests {

  @Test("skippedAlreadyReady: no log, no PostHog, no Sentry, no real load")
  func skippedAlreadyReady() {
    let plan = OutputClassifierEmissionPolicy.forOutcome(.skippedAlreadyReady)
    #expect(plan.logMessage == nil)
    #expect(plan.postHogErrorCategory == nil)
    #expect(plan.sentryReason == nil)
    #expect(plan.attemptedRealLoad == false)
    #expect(plan.postHogResult == nil)
  }

  @Test("skippedLoadInProgress: no log, no PostHog, no Sentry, no real load")
  func skippedLoadInProgress() {
    let plan = OutputClassifierEmissionPolicy.forOutcome(.skippedLoadInProgress)
    #expect(plan.logMessage == nil)
    #expect(plan.postHogErrorCategory == nil)
    #expect(plan.sentryReason == nil)
    #expect(plan.attemptedRealLoad == false)
    #expect(plan.postHogResult == nil)
  }

  @Test("succeeded: logs, no PostHog, no Sentry, real load")
  func succeeded() {
    let plan = OutputClassifierEmissionPolicy.forOutcome(.succeeded)
    #expect(plan.logMessage != nil)
    #expect(plan.postHogErrorCategory == nil)
    #expect(plan.sentryReason == nil)
    #expect(plan.attemptedRealLoad == true)
    #expect(plan.postHogResult == nil)
  }

  @Test(
    "succeededViaFallback: logs, PostHog counts succeeded_via_fallback tagged recovered (not fell_open), NEVER alerts Sentry, real load"
  )
  func succeededViaFallback() {
    let plan = OutputClassifierEmissionPolicy.forOutcome(
      .succeededViaFallback(primaryReason: .fixtureSelfTestFailed))
    #expect(plan.logMessage != nil)
    #expect(plan.postHogErrorCategory == "succeeded_via_fallback:fixture_selftest_failed")
    #expect(plan.sentryReason == nil)  // Fallback, not Failure — the classifier is active
    #expect(plan.attemptedRealLoad == true)
    #expect(plan.postHogResult == "recovered")
  }

  @Test(
    "skippedPermanentlyDisabled: PostHog counts it as suppressed_repeat tagged fell_open (unchanged), NEVER alerts Sentry, no real load"
  )
  func skippedPermanentlyDisabled() {
    let plan = OutputClassifierEmissionPolicy.forOutcome(
      .skippedPermanentlyDisabled(reason: .fixtureSelfTestFailed))
    #expect(plan.logMessage == nil)
    #expect(plan.postHogErrorCategory == "suppressed_repeat:fixture_selftest_failed")
    #expect(plan.sentryReason == nil)  // this IS the fix — no re-alert
    #expect(plan.attemptedRealLoad == false)
    #expect(plan.postHogResult == "fell_open")  // #1226: unchanged by the new field
  }

  @Test(
    "failedNoRetry: logs, PostHog counts attempted_load tagged fell_open, Sentry alerts exactly this once, real load"
  )
  func failedNoRetry() {
    let plan = OutputClassifierEmissionPolicy.forOutcome(
      .failedNoRetry(reason: .modelLoadFailed))
    #expect(plan.logMessage != nil)
    #expect(plan.postHogErrorCategory == "attempted_load:model_load_failed")
    #expect(plan.sentryReason == .modelLoadFailed)
    #expect(plan.attemptedRealLoad == true)
    #expect(plan.postHogResult == "fell_open")
  }

  @Test(
    "failedAfterFallback: logs and PostHog category carry BOTH reasons distinctly, Sentry alerts, real load"
  )
  func failedAfterFallback() {
    let plan = OutputClassifierEmissionPolicy.forOutcome(
      .failedAfterFallback(primaryReason: .fixtureSelfTestFailed, fallbackReason: .modelLoadFailed))
    #expect(plan.logMessage != nil)
    #expect(
      plan.postHogErrorCategory == "exhausted_fallback:fixture_selftest_failed->model_load_failed")
    #expect(plan.sentryReason == .modelLoadFailed)
    #expect(plan.attemptedRealLoad == true)
    #expect(plan.postHogResult == "fell_open")
  }

  @Test(
    "failedRetryable: PostHog counts it as retryable tagged fell_open (unchanged), NEVER alerts Sentry, real load"
  )
  func failedRetryable() {
    let plan = OutputClassifierEmissionPolicy.forOutcome(
      .failedRetryable(errorCategory: "cancelled"))
    #expect(plan.logMessage == nil)
    #expect(plan.postHogErrorCategory == "retryable:cancelled")
    #expect(plan.sentryReason == nil)
    #expect(plan.attemptedRealLoad == true)
    #expect(plan.postHogResult == "fell_open")  // #1226: unchanged by the new field
  }

  @Test("attemptedRealLoad is true for exactly the 5 outcomes that ran a real load")
  func attemptedRealLoadPartitionsCorrectly() {
    let outcomes: [(OutputClassifierAttemptOutcome, Bool)] = [
      (.skippedAlreadyReady, false),
      (.skippedLoadInProgress, false),
      (.skippedPermanentlyDisabled(reason: .missingFile), false),
      (.succeeded, true),
      (.succeededViaFallback(primaryReason: .fixtureSelfTestFailed), true),
      (.failedNoRetry(reason: .missingFile), true),
      (
        .failedAfterFallback(primaryReason: .fixtureSelfTestFailed, fallbackReason: .missingFile),
        true
      ),
      (.failedRetryable(errorCategory: "unknown_load_error"), true),
    ]
    for (outcome, expected) in outcomes {
      #expect(OutputClassifierEmissionPolicy.forOutcome(outcome).attemptedRealLoad == expected)
    }
  }

  @Test(
    "sentryReason is non-nil for exactly the 2 genuine-failure outcomes: failedNoRetry, failedAfterFallback"
  )
  func sentryReasonOnlyOnGenuineFailures() {
    let outcomes: [OutputClassifierAttemptOutcome] = [
      .skippedAlreadyReady,
      .skippedLoadInProgress,
      .skippedPermanentlyDisabled(reason: .missingFile),
      .succeeded,
      .succeededViaFallback(primaryReason: .fixtureSelfTestFailed),
      .failedNoRetry(reason: .missingFile),
      .failedAfterFallback(primaryReason: .fixtureSelfTestFailed, fallbackReason: .missingFile),
      .failedRetryable(errorCategory: "cancelled"),
    ]
    let alertingOutcomes = outcomes.filter {
      OutputClassifierEmissionPolicy.forOutcome($0).sentryReason != nil
    }
    #expect(alertingOutcomes.count == 2)
  }

  @Test("postHogResult is non-nil exactly when postHogErrorCategory is non-nil")
  func postHogResultMatchesCategoryNilness() {
    let outcomes: [OutputClassifierAttemptOutcome] = [
      .skippedAlreadyReady,
      .skippedLoadInProgress,
      .succeeded,
      .succeededViaFallback(primaryReason: .fixtureSelfTestFailed),
      .skippedPermanentlyDisabled(reason: .missingFile),
      .failedNoRetry(reason: .missingFile),
      .failedAfterFallback(primaryReason: .fixtureSelfTestFailed, fallbackReason: .missingFile),
      .failedRetryable(errorCategory: "cancelled"),
    ]
    for outcome in outcomes {
      let plan = OutputClassifierEmissionPolicy.forOutcome(outcome)
      #expect(
        (plan.postHogResult != nil) == (plan.postHogErrorCategory != nil),
        "postHogResult and postHogErrorCategory must be nil/non-nil together for \(outcome)")
    }
  }
}
