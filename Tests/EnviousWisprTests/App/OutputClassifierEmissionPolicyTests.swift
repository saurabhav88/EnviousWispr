import EnviousWisprLLM
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #1452: `OutputClassifierEmissionPolicy.forOutcome` is the actual
/// alert-dedup contract — the outcome→emission decision `WisprBootstrapper`
/// executes. Exhaustively covers all 6 `OutputClassifierAttemptOutcome` cases
/// so a wrong `switch` arm (e.g. alerting on a suppressed repeat) fails here
/// instead of only being discoverable by reading the switch statement.
@Suite("OutputClassifierEmissionPolicy.forOutcome")
struct OutputClassifierEmissionPolicyTests {

  @Test("skippedAlreadyReady: no log, no PostHog, no Sentry, no real load")
  func skippedAlreadyReady() {
    let plan = OutputClassifierEmissionPolicy.forOutcome(.skippedAlreadyReady)
    #expect(plan.logMessage == nil)
    #expect(plan.postHogErrorCategory == nil)
    #expect(plan.sentryReason == nil)
    #expect(plan.attemptedRealLoad == false)
  }

  @Test("skippedLoadInProgress: no log, no PostHog, no Sentry, no real load")
  func skippedLoadInProgress() {
    let plan = OutputClassifierEmissionPolicy.forOutcome(.skippedLoadInProgress)
    #expect(plan.logMessage == nil)
    #expect(plan.postHogErrorCategory == nil)
    #expect(plan.sentryReason == nil)
    #expect(plan.attemptedRealLoad == false)
  }

  @Test("succeeded: logs, no PostHog, no Sentry, real load")
  func succeeded() {
    let plan = OutputClassifierEmissionPolicy.forOutcome(.succeeded)
    #expect(plan.logMessage != nil)
    #expect(plan.postHogErrorCategory == nil)
    #expect(plan.sentryReason == nil)
    #expect(plan.attemptedRealLoad == true)
  }

  @Test(
    "skippedPermanentlyDisabled: PostHog counts it as suppressed_repeat, NEVER alerts Sentry, no real load"
  )
  func skippedPermanentlyDisabled() {
    let plan = OutputClassifierEmissionPolicy.forOutcome(
      .skippedPermanentlyDisabled(reason: .fixtureSelfTestFailed))
    #expect(plan.logMessage == nil)
    #expect(plan.postHogErrorCategory == "suppressed_repeat:fixture_selftest_failed")
    #expect(plan.sentryReason == nil)  // this IS the fix — no re-alert
    #expect(plan.attemptedRealLoad == false)
  }

  @Test(
    "failedFirstTime: logs, PostHog counts attempted_load, Sentry alerts exactly this once, real load"
  )
  func failedFirstTime() {
    let plan = OutputClassifierEmissionPolicy.forOutcome(
      .failedFirstTime(reason: .modelLoadFailed))
    #expect(plan.logMessage != nil)
    #expect(plan.postHogErrorCategory == "attempted_load:model_load_failed")
    #expect(plan.sentryReason == .modelLoadFailed)
    #expect(plan.attemptedRealLoad == true)
  }

  @Test("failedRetryable: PostHog counts it as retryable, NEVER alerts Sentry, real load")
  func failedRetryable() {
    let plan = OutputClassifierEmissionPolicy.forOutcome(
      .failedRetryable(errorCategory: "cancelled"))
    #expect(plan.logMessage == nil)
    #expect(plan.postHogErrorCategory == "retryable:cancelled")
    #expect(plan.sentryReason == nil)
    #expect(plan.attemptedRealLoad == true)
  }

}
