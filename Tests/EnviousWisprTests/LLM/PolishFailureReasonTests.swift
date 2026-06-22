import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprLLM

/// #945: the closed `PolishFailureReason` catalog — the single adapter that owns
/// telemetry tag, lead-in, per-provider message, retryability, and the mapping
/// from the errors the runner sees directly to a reason.
@Suite("PolishFailureReason")
struct PolishFailureReasonTests {

  // MARK: - Telemetry tags

  @Test(
    "each reason has its stable low-cardinality telemetry tag",
    arguments: [
      (PolishFailureReason.apiKeyMissing, "api_key_missing"),
      (.apiKeyRejected, "api_key_rejected"),
      (.accessDenied, "access_denied"),
      (.outOfCredits, "out_of_credits"),
      (.rateLimited, "rate_limited"),
      (.rateLimitedOrQuota, "rate_or_quota"),
      (.modelUnavailable, "model_unavailable"),
      (.inputTooLong, "input_too_long"),
      (.contentBlocked, "content_blocked"),
      (.providerUnreachable, "provider_unreachable"),
      (.providerServerError, "provider_server_error"),
      (.badRequest, "bad_request"),
      (.emptyResponse, "empty_response"),
      (.timedOut, "timed_out"),
      (.unknown, "unknown"),
    ])
  func telemetryTags(reason: PolishFailureReason, expected: String) {
    #expect(reason.telemetryTag == expected)
  }

  @Test("telemetry tags are unique across all reasons")
  func telemetryTagsUnique() {
    let tags = PolishFailureReason.allCases.map(\.telemetryTag)
    #expect(Set(tags).count == tags.count)
  }

  // MARK: - Lead-in (skipped vs failed)

  @Test(
    "not-really-broken reasons lead with 'AI cleanup skipped:'",
    arguments: [
      PolishFailureReason.apiKeyMissing,
      PolishFailureReason.inputTooLong,
      PolishFailureReason.timedOut,
    ])
  func skippedLeadIn(reason: PolishFailureReason) {
    #expect(reason.leadIn == .skipped)
    #expect(reason.leadIn.text == "AI cleanup skipped:")
  }

  @Test(
    "real-error reasons lead with 'AI polish failed:'",
    arguments: [
      PolishFailureReason.apiKeyRejected,
      PolishFailureReason.accessDenied,
      PolishFailureReason.outOfCredits,
      PolishFailureReason.rateLimited,
      PolishFailureReason.rateLimitedOrQuota,
      PolishFailureReason.modelUnavailable,
      PolishFailureReason.contentBlocked,
      PolishFailureReason.providerUnreachable,
      PolishFailureReason.providerServerError,
      PolishFailureReason.badRequest,
      PolishFailureReason.emptyResponse,
      PolishFailureReason.unknown,
    ])
  func failedLeadIn(reason: PolishFailureReason) {
    #expect(reason.leadIn == .failed)
    #expect(reason.leadIn.text == "AI polish failed:")
  }

  // MARK: - Retryability

  @Test("only server-error and rate-limited are retryable")
  func retryability() {
    for reason in PolishFailureReason.allCases {
      let expected = reason == .providerServerError || reason == .rateLimited
      #expect(reason.isRetryable == expected, "\(reason) retryable should be \(expected)")
    }
  }

  // MARK: - Messages (copy)

  @Test("the out-of-credits message names billing, never 'rate limited' (the bug it fixes)")
  func outOfCreditsCopy() {
    let msg = PolishFailureReason.outOfCredits.composedMessage(provider: .openAI)
    #expect(
      msg == "AI polish failed: your OpenAI account is out of credits. Check your provider billing."
    )
    #expect(!msg.lowercased().contains("rate limit"))
  }

  @Test("missing-key message uses the skipped lead-in and points to Settings")
  func apiKeyMissingCopy() {
    let msg = PolishFailureReason.apiKeyMissing.composedMessage(provider: .gemini)
    #expect(msg == "AI cleanup skipped: no Gemini API key set yet. Add one in Settings.")
  }

  @Test("Gemini rate-or-quota copy names BOTH (Gemini cannot split them)")
  func rateOrQuotaCopy() {
    let msg = PolishFailureReason.rateLimitedOrQuota.composedMessage(provider: .gemini)
    #expect(msg.contains("rate or quota"))
    #expect(msg.contains("billing"))
  }

  @Test("model-unavailable and unreachable have distinct Ollama vs cloud variants")
  func ollamaSpecificCopy() {
    let cloudModel = PolishFailureReason.modelUnavailable.message(provider: .openAI)
    let ollamaModel = PolishFailureReason.modelUnavailable.message(provider: .ollama)
    #expect(cloudModel.contains("OpenAI model"))
    #expect(ollamaModel.contains("Ollama"))
    #expect(cloudModel != ollamaModel)

    let cloudReach = PolishFailureReason.providerUnreachable.message(provider: .gemini)
    let ollamaReach = PolishFailureReason.providerUnreachable.message(provider: .ollama)
    #expect(cloudReach.contains("internet connection"))
    #expect(ollamaReach.contains("Start Ollama"))
    #expect(cloudReach != ollamaReach)
  }

  @Test("the generic fallback lines read cleanly after their lead-in (no restated lead-in)")
  func genericFallbackCopyTightened() {
    // Founder-approved tightening (2026-06-22): these three compose without
    // repeating the lead-in (no "AI cleanup skipped: AI cleanup took too long").
    #expect(
      PolishFailureReason.timedOut.composedMessage(provider: .openAI)
        == "AI cleanup skipped: the dictation took too long. Your original text was pasted unchanged."
    )
    #expect(
      PolishFailureReason.badRequest.composedMessage(provider: .openAI)
        == "AI polish failed: a configuration problem stopped it. Your original text was pasted unchanged."
    )
    #expect(
      PolishFailureReason.unknown.composedMessage(provider: .openAI)
        == "AI polish failed: an unexpected error stopped it. Your original text was pasted unchanged."
    )
  }

  @Test("composedMessage is exactly '<leadIn> <message>'")
  func composedShape() {
    for reason in PolishFailureReason.allCases {
      let composed = reason.composedMessage(provider: .openAI)
      let expected = "\(reason.leadIn.text) \(reason.message(provider: .openAI))"
      #expect(composed == expected)
    }
  }

  @Test("no message uses em-dashes or en-dashes (human-facing copy rule)")
  func noFancyDashes() {
    for reason in PolishFailureReason.allCases {
      for provider in [LLMProvider.openAI, .gemini, .ollama] {
        let msg = reason.composedMessage(provider: provider)
        #expect(!msg.contains("\u{2014}"), "\(reason)/\(provider) contains em-dash")
        #expect(!msg.contains("\u{2013}"), "\(reason)/\(provider) contains en-dash")
      }
    }
  }

  // MARK: - from(_:) mapping

  @Test("from unwraps the .classified carrier to its reason")
  func fromUnwrapsClassified() {
    for reason in PolishFailureReason.allCases {
      #expect(PolishFailureReason.from(LLMError.classified(reason)) == reason)
    }
  }

  @Test(
    "from maps the legacy LLMError cases connectors still throw on the polish path",
    arguments: [
      (LLMError.invalidAPIKey, PolishFailureReason.apiKeyRejected),
      (.rateLimited, .rateLimited),
      (.emptyResponse, .emptyResponse),
      (.providerUnavailable, .providerUnreachable),
      (.modelNotFound("llama3"), .modelUnavailable),
      (.requestFailed("Ollama server error (HTTP 503)"), .providerServerError),
      (.requestFailed("Invalid response"), .badRequest),
    ])
  func fromMapsLegacyCases(error: LLMError, expected: PolishFailureReason) {
    #expect(PolishFailureReason.from(error) == expected)
  }

  @Test("from maps the runner's own TimeoutError to timedOut")
  func fromMapsTimeout() {
    #expect(PolishFailureReason.from(TimeoutError(seconds: 5)) == .timedOut)
  }

  @Test(
    "from maps connectivity URLErrors to providerUnreachable",
    arguments: [
      URLError.Code.notConnectedToInternet,
      URLError.Code.cannotFindHost,
      URLError.Code.cannotConnectToHost,
      URLError.Code.networkConnectionLost,
      URLError.Code.timedOut,
      URLError.Code.dnsLookupFailed,
    ])
  func fromMapsURLErrors(code: URLError.Code) {
    #expect(PolishFailureReason.from(URLError(code)) == .providerUnreachable)
  }

  @Test("from maps an unrecognized error to unknown")
  func fromMapsUnknown() {
    #expect(PolishFailureReason.from(NSError(domain: "x", code: 1)) == .unknown)
  }

  // MARK: - Adversarial (matcher-set-adversarial-tests)

  @Test("a rate limit is NOT classified as out-of-credits, and vice versa")
  func rateVsCreditsDistinct() {
    #expect(PolishFailureReason.rateLimited != .outOfCredits)
    #expect(
      PolishFailureReason.rateLimited.telemetryTag != PolishFailureReason.outOfCredits.telemetryTag)
    // The out-of-credits user must never be told to "try again in a moment".
    #expect(
      !PolishFailureReason.outOfCredits.message(provider: .openAI).lowercased().contains(
        "try again"))
  }

  @Test("a present-but-rejected key is NOT the missing-key (skipped) reason")
  func rejectedVsMissingDistinct() {
    #expect(PolishFailureReason.apiKeyRejected.leadIn == .failed)
    #expect(PolishFailureReason.apiKeyMissing.leadIn == .skipped)
  }
}
