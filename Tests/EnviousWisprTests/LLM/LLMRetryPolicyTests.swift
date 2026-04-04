import Foundation
import Testing
@testable import EnviousWisprLLM

@Suite("LLMRetryPolicy")
struct LLMRetryPolicyTests {

    // MARK: - Constants

    @Test("default delays are 1s and 3s")
    func defaultDelays() {
        #expect(LLMRetryPolicy.defaultDelays == [1_000_000_000, 3_000_000_000])
    }

    @Test("default max retries is 2")
    func defaultMaxRetries() {
        #expect(LLMRetryPolicy.defaultMaxRetries == 2)
    }

    // MARK: - LLMError retryable cases

    @Test("rateLimited is retryable")
    func rateLimitedRetryable() {
        #expect(LLMRetryPolicy.isRetryable(LLMError.rateLimited))
    }

    @Test("requestFailed with server error is retryable")
    func serverErrorRetryable() {
        #expect(LLMRetryPolicy.isRetryable(LLMError.requestFailed("server error")))
    }

    @Test("requestFailed containing server error substring is retryable")
    func serverErrorSubstringRetryable() {
        #expect(LLMRetryPolicy.isRetryable(LLMError.requestFailed("internal server error occurred")))
    }

    @Test("non-retryable LLM errors", arguments: [
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

    // MARK: - URLError retryable cases

    @Test("retryable URLError codes", arguments: [
        URLError.Code.timedOut,
        URLError.Code.networkConnectionLost,
        URLError.Code.cannotConnectToHost,
    ])
    func retryableURLErrors(code: URLError.Code) {
        #expect(LLMRetryPolicy.isRetryable(URLError(code)))
    }

    @Test("non-retryable URLError codes", arguments: [
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
