import Foundation
import Testing

@testable import EnviousWisprLLM

@Suite("LLMRetryPolicy")
struct LLMRetryPolicyTests {

  // MARK: - Constants

  @Test("default delays are 200ms and 400ms")
  func defaultDelays() {
    #expect(LLMRetryPolicy.defaultDelays == [200_000_000, 400_000_000])
  }

  /// #2093: the durable claim is not the two literals above — it is that the
  /// SLEEPS cannot eat the budget they run inside. They are spent within the
  /// polish step's own deadline, so at 1s+3s a single transient 5xx made a short
  /// cloud dictation's timeout arithmetically certain on the old 5s base, and
  /// the user was told "timed out" instead of the real reason.
  ///
  /// Stated as a RELATION against the smallest cloud budget rather than as a
  /// third copy of the numbers, so it stays true if the delays are retuned and
  /// goes red if anyone reintroduces multi-second backoff.
  @Test("all retry sleeps together stay well inside the smallest cloud budget")
  func retrySleepsFitInsideTheBudget() {
    let totalSleepNanos = LLMRetryPolicy.defaultDelays.reduce(0, +)
    let totalSleepSeconds = Double(totalSleepNanos) / 1_000_000_000
    #expect(totalSleepSeconds < 1.0)
    // The smallest cloud budget any dictation can get is the 15s base (#2093).
    #expect(totalSleepSeconds < 15.0 * 0.1)
  }

  @Test("default max retries is 2")
  func defaultMaxRetries() {
    #expect(LLMRetryPolicy.defaultMaxRetries == 2)
  }

  // MARK: - LLMError retryable cases

  /// #2641: `LLMError.rateLimited` has no producer — the connectors classify a
  /// 429 into `.classified(.rateLimited)` (retried, asserted below) or
  /// `.classified(.rateLimitedOrQuota)` (fail-fast). The bare case used to
  /// carry a retry that nothing could reach; it is pinned non-retryable so a
  /// future producer has to choose to retry rather than inherit it.
  @Test("bare rateLimited has no producer and is not retryable")
  func bareRateLimitedNotRetryable() {
    #expect(!LLMRetryPolicy.isRetryable(LLMError.rateLimited))
  }

  @Test("requestFailed with server error is retryable")
  func serverErrorRetryable() {
    #expect(LLMRetryPolicy.isRetryable(LLMError.requestFailed("server error")))
  }

  @Test("requestFailed containing server error substring is retryable")
  func serverErrorSubstringRetryable() {
    #expect(LLMRetryPolicy.isRetryable(LLMError.requestFailed("internal server error occurred")))
  }

  @Test(
    "non-retryable LLM errors",
    arguments: [
      LLMError.invalidAPIKey,
      LLMError.emptyResponse,
      LLMError.providerUnavailable,
      LLMError.modelNotFound("llama3"),
      LLMError.frameworkUnavailable("FoundationModels not available"),
      LLMError.requestFailed("bad request"),
      LLMError.requestFailed("authentication failed"),
    ])
  func nonRetryableLLMErrors(error: LLMError) {
    #expect(!LLMRetryPolicy.isRetryable(error))
  }

  // MARK: - Classified-reason arm (#945)

  @Test(
    "classified server error stays retryable (5xx-retry preservation regression)")
  func classifiedServerErrorRetryable() {
    // Before #945, a 5xx rode on `requestFailed(\"...server error...\")` whose
    // string-match made it retryable. The connectors now throw
    // `.classified(.providerServerError)`; this must keep retrying transient
    // outages or we silently stop retrying them.
    #expect(LLMRetryPolicy.isRetryable(LLMError.classified(.providerServerError)))
  }

  @Test("classified rate-limited stays retryable")
  func classifiedRateLimitedRetryable() {
    #expect(LLMRetryPolicy.isRetryable(LLMError.classified(.rateLimited)))
  }

  @Test(
    "classified fail-fast reasons are NOT retryable",
    arguments: [
      PolishFailureReason.apiKeyMissing,
      PolishFailureReason.apiKeyRejected,
      PolishFailureReason.accessDenied,
      PolishFailureReason.outOfCredits,
      PolishFailureReason.rateLimitedOrQuota,
      PolishFailureReason.modelUnavailable,
      PolishFailureReason.inputTooLong,
      PolishFailureReason.contentBlocked,
      PolishFailureReason.providerUnreachable,
      PolishFailureReason.badRequest,
      PolishFailureReason.emptyResponse,
      PolishFailureReason.timedOut,
      PolishFailureReason.unknown,
    ])
  func classifiedFailFastNotRetryable(reason: PolishFailureReason) {
    #expect(!LLMRetryPolicy.isRetryable(LLMError.classified(reason)))
  }

  // MARK: - URLError retryable cases

  @Test(
    "retryable URLError codes",
    arguments: [
      URLError.Code.timedOut,
      URLError.Code.networkConnectionLost,
      URLError.Code.cannotConnectToHost,
    ])
  func retryableURLErrors(code: URLError.Code) {
    #expect(LLMRetryPolicy.isRetryable(URLError(code)))
  }

  @Test(
    "non-retryable URLError codes",
    arguments: [
      URLError.Code.badURL,
      URLError.Code.unsupportedURL,
      URLError.Code.badServerResponse,
      URLError.Code.cancelled,
    ])
  func nonRetryableURLErrors(code: URLError.Code) {
    #expect(!LLMRetryPolicy.isRetryable(URLError(code)))
  }

  // MARK: - Generic errors

  @Test("generic NSError is not retryable")
  func genericErrorNotRetryable() {
    let error = NSError(domain: "test", code: 42)
    #expect(!LLMRetryPolicy.isRetryable(error))
  }

  @Test("requestFailed with empty message is not retryable")
  func emptyMessageNotRetryable() {
    #expect(!LLMRetryPolicy.isRetryable(LLMError.requestFailed("")))
  }
}
