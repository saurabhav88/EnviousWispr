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
      (.apiKeyUnreadable, "api_key_unreadable"),
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
      PolishFailureReason.apiKeyUnreadable,
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
      for provider in [LLMProvider.openAI, .gemini, .claude, .ollama] {
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

  // MARK: - Telemetry channel (#1446)

  /// OUR bugs, on any provider: a request we built wrong, a response we mis-parsed,
  /// an error we failed to classify, a key we stored and then could not read, and
  /// the polish budget WE set expiring. Spelled out longhand rather than derived
  /// from the production switch, so changing the policy forces a deliberate edit
  /// here too.
  private static let alwaysAlerting: Set<PolishFailureReason> = [
    .badRequest, .emptyResponse, .unknown, .apiKeyUnreadable, .timedOut,
  ]
  /// The one reason whose MEANING depends on where the provider runs: a model the
  /// user never pulled into Ollama is their setup; a cloud model our Picker offered
  /// and the provider then 404s is a dead id in our catalog.
  private static let alertingUnlessOllama: Set<PolishFailureReason> = [
    .modelUnavailable
  ]
  /// Everything the user or the provider owns: their network, machine, key, account,
  /// billing, quota, dictation length, and the provider's own outage and content
  /// rules. Counted, never paged — no code change of ours alters the outcome, so a
  /// GitHub issue would have nothing to fix. The COUNT is the point: it tells us
  /// which walls users hit, which we answer with guides, not commits.
  private static let neverAlerting: Set<PolishFailureReason> = [
    .providerUnreachable, .apiKeyMissing, .apiKeyRejected, .accessDenied,
    .outOfCredits, .rateLimited, .rateLimitedOrQuota, .providerServerError,
    .contentBlocked, .inputTooLong,
    // #1710: with no client ceiling (or Claude's generous fixed cap), a
    // truncation is the provider's own per-model limit — their condition.
    .outputTruncated,
  ]

  @Test(
    "the three expectation sets above partition every reason (no case silently untested)",
    .bug(
      "https://github.com/saurabhav88/EnviousWispr/issues/1446",
      "user-environment polish failures fired alerting Sentry errors")
  )
  func channelExpectationSetsPartitionAllCases() {
    let union = Self.alwaysAlerting.union(Self.alertingUnlessOllama).union(Self.neverAlerting)
    #expect(union == Set(PolishFailureReason.allCases))
    let overlap =
      Self.alwaysAlerting.intersection(Self.alertingUnlessOllama)
      .union(Self.alwaysAlerting.intersection(Self.neverAlerting))
      .union(Self.alertingUnlessOllama.intersection(Self.neverAlerting))
    #expect(overlap.isEmpty)
  }

  @Test(
    "every (reason x provider) pair lands in its pinned channel",
    .bug(
      "https://github.com/saurabhav88/EnviousWispr/issues/1446",
      "user-environment polish failures fired alerting Sentry errors"),
    arguments: PolishFailureReason.allCases, [LLMProvider.openAI, .gemini, .claude, .ollama]
  )
  func telemetryChannelMatrix(reason: PolishFailureReason, provider: LLMProvider) {
    let expected: PolishFailureTelemetryChannel
    if Self.alwaysAlerting.contains(reason) {
      expected = .alertingSentryError
    } else if Self.alertingUnlessOllama.contains(reason) {
      expected = provider == .ollama ? .nonAlertingAnalytics : .alertingSentryError
    } else {
      expected = .nonAlertingAnalytics
    }
    #expect(
      reason.telemetryChannel(provider: provider) == expected,
      "\(reason) on \(provider) should be \(expected)")
  }

  @Test("the provider-keyed reason is the whole point: same reason, opposite channels")
  func providerKeyedChannelsDiverge() {
    for reason in Self.alertingUnlessOllama {
      #expect(reason.telemetryChannel(provider: .ollama) == .nonAlertingAnalytics)
      #expect(reason.telemetryChannel(provider: .openAI) == .alertingSentryError)
      #expect(reason.telemetryChannel(provider: .gemini) == .alertingSentryError)
      #expect(reason.telemetryChannel(provider: .claude) == .alertingSentryError)
    }
  }

  /// A user on a plane, on a train, behind a corporate firewall, or with a VPN up
  /// must never page us — on ANY provider. `from(_:)` maps every one of these
  /// `URLError`s onto `.providerUnreachable`, so the channel must hold for all of
  /// them. This is the founder principle in `sentry-operations.md`
  /// RULE: sentry-for-bugs-posthog-for-behaviour, which names "network" outright.
  @Test(
    "a user network outage is counted, never paged, on every provider",
    .bug(
      "https://github.com/saurabhav88/EnviousWispr/issues/1446",
      "cloud providerUnreachable alerted on the user's own network"),
    arguments: [
      URLError.Code.notConnectedToInternet,
      URLError.Code.networkConnectionLost,
      URLError.Code.dataNotAllowed,
      URLError.Code.internationalRoamingOff,
      URLError.Code.cannotFindHost,
      URLError.Code.cannotConnectToHost,
      URLError.Code.dnsLookupFailed,
      URLError.Code.timedOut,
    ]
  )
  func userNetworkOutagesNeverAlert(code: URLError.Code) {
    let reason = PolishFailureReason.from(URLError(code))
    #expect(reason == .providerUnreachable)
    for provider in [LLMProvider.openAI, .gemini, .claude, .ollama] {
      #expect(reason.telemetryChannel(provider: provider) == .nonAlertingAnalytics)
    }
  }

  /// The counterpart: OUR polish budget expiring is `TimeoutError`, not a `URLError`,
  /// and it stays alerting. A budget that shrank or a prompt that ballooned is our
  /// regression, and the two timeouts must not collapse into one channel.
  @Test("our own polish-budget timeout still pages us, unlike a network timeout")
  func ourBudgetTimeoutStillAlerts() {
    #expect(PolishFailureReason.from(TimeoutError(seconds: 5)) == .timedOut)
    #expect(
      PolishFailureReason.timedOut.telemetryChannel(provider: .openAI) == .alertingSentryError)
    #expect(
      PolishFailureReason.from(URLError(.timedOut)).telemetryChannel(provider: .openAI)
        == .nonAlertingAnalytics)
  }

  @Test("the user- and provider-owned reasons never page us, on any provider")
  func userEnvironmentReasonsNeverAlert() {
    for reason in Self.neverAlerting {
      for provider in [LLMProvider.openAI, .gemini, .claude, .ollama] {
        #expect(reason.telemetryChannel(provider: provider) == .nonAlertingAnalytics)
      }
    }
  }

  /// Four reasons tell the user "AI cleanup skipped" — nothing is broken. Exactly two
  /// of them still page us, and both are OURS despite the reassuring copy:
  ///   - `timedOut` — the deadline it blew is a budget WE chose, so a spike means our
  ///     budget shrank or our prompt ballooned.
  ///   - `apiKeyUnreadable` — we stored a key and then could not read it back. Its
  ///     copy is deliberately identical to `apiKeyMissing` (re-entering the key fixes
  ///     both), but only this one is a defect.
  /// The other two are the user's own situation and are counted only. Pinned so a
  /// future tidy-up cannot collapse the notice and the channel into each other: they
  /// answer different questions — "is the user alarmed?" vs "is this our bug?"
  @Test("the only reassuring-looking reasons that still page us are the two that are ours")
  func onlyOurOwnFailuresAlertAmongSkipNotices() {
    let skipNoticeReasons = PolishFailureReason.allCases.filter { $0.leadIn == .skipped }
    #expect(
      Set(skipNoticeReasons) == [.apiKeyMissing, .apiKeyUnreadable, .inputTooLong, .timedOut])

    let alertingSkipNotices = skipNoticeReasons.filter {
      $0.telemetryChannel(provider: .openAI) == .alertingSentryError
    }
    #expect(Set(alertingSkipNotices) == [.timedOut, .apiKeyUnreadable])
  }

  /// The whole point, stated once: alerting is reserved for OUR bugs.
  @Test("nothing outside EnviousWispr's own defects can reach the alerting channel")
  func alertingSetIsExactlyOurBugs() {
    var alerting: Set<PolishFailureReason> = []
    for reason in PolishFailureReason.allCases {
      for provider in [LLMProvider.openAI, .gemini, .claude, .ollama] {
        if reason.telemetryChannel(provider: provider) == .alertingSentryError {
          alerting.insert(reason)
        }
      }
    }
    #expect(
      alerting == [
        .badRequest, .emptyResponse, .unknown, .apiKeyUnreadable, .timedOut,
        .modelUnavailable,  // cloud only; Ollama's is the user's un-pulled model
      ])
  }

  // MARK: - The apiKeyMissing / apiKeyUnreadable split (#1446)

  @Test(
    "apiKeyUnreadable is byte-identical to apiKeyMissing everywhere the USER can see",
    .bug(
      "https://github.com/saurabhav88/EnviousWispr/issues/1446",
      "a Keychain-read defect hid behind a user-configuration state")
  )
  func unreadableKeyCopyParity() {
    let unreadable = PolishFailureReason.apiKeyUnreadable
    let missing = PolishFailureReason.apiKeyMissing
    for provider in [LLMProvider.openAI, .gemini, .claude, .ollama] {
      #expect(unreadable.message(provider: provider) == missing.message(provider: provider))
      #expect(
        unreadable.composedMessage(provider: provider)
          == missing.composedMessage(provider: provider))
      // The completion planner keys the skip-vs-hard-failure toast off this.
      #expect(PolishFailureReason.isSkipNotice(unreadable.composedMessage(provider: provider)))
    }
    #expect(unreadable.leadIn == missing.leadIn)
    #expect(unreadable.leadIn == .skipped)
    #expect(unreadable.isRetryable == missing.isRetryable)
    #expect(unreadable.isRetryable == false)
  }

  @Test("...and differs from apiKeyMissing in exactly the two ways that motivated the split")
  func unreadableKeyTelemetryDiverges() {
    // A distinct Sentry fingerprint...
    #expect(PolishFailureReason.apiKeyUnreadable.telemetryTag == "api_key_unreadable")
    #expect(
      PolishFailureReason.apiKeyUnreadable.telemetryTag
        != PolishFailureReason.apiKeyMissing.telemetryTag)
    // ...and the opposite channel: our defect pages, the user's config does not.
    for provider in [LLMProvider.openAI, .gemini, .claude, .ollama] {
      #expect(
        PolishFailureReason.apiKeyUnreadable.telemetryChannel(provider: provider)
          == .alertingSentryError)
      #expect(
        PolishFailureReason.apiKeyMissing.telemetryChannel(provider: provider)
          == .nonAlertingAnalytics)
    }
  }

  // MARK: - Output truncation (#1710) — RED-first against chunk-1 HEAD

  @Test("outputTruncated exists in the catalog with tag output_truncated")
  func outputTruncatedCaseExists() throws {
    // Written as a dynamic rawValue lookup during the RED phase (compiled
    // against pre-fix code, failed on nil); now also pinned to the typed case.
    let reason = try #require(PolishFailureReason(rawValue: "outputTruncated"))
    #expect(reason == .outputTruncated)
    #expect(reason.telemetryTag == "output_truncated")
    #expect(PolishFailureReason.allCases.contains(.outputTruncated))
  }

  @Test("outputTruncated tag stays unique in the catalog")
  func outputTruncatedTagUnique() {
    let tags = PolishFailureReason.allCases.map(\.telemetryTag)
    #expect(tags.filter { $0 == "output_truncated" }.count == 1)
  }

  @Test("outputTruncated leads with failed, never retries")
  func outputTruncatedLeadInAndRetry() {
    #expect(PolishFailureReason.outputTruncated.leadIn == .failed)
    #expect(PolishFailureReason.outputTruncated.isRetryable == false)
  }

  @Test("outputTruncated is non-alerting for every provider")
  func outputTruncatedChannelNonAlertingEverywhere() {
    for provider in LLMProvider.allCases {
      #expect(
        PolishFailureReason.outputTruncated.telemetryChannel(provider: provider)
          == .nonAlertingAnalytics)
    }
  }

  @Test("outputTruncated composed copy is exact per cloud provider")
  func outputTruncatedComposedCopy() {
    for (provider, name) in [
      (LLMProvider.openAI, "OpenAI"), (.gemini, "Gemini"), (.claude, "Claude"),
    ] {
      #expect(
        PolishFailureReason.outputTruncated.composedMessage(provider: provider)
          == "AI polish failed: \(name) ended the response before cleanup finished. "
          + "EnviousWispr kept your complete original text instead. "
          + "If this keeps happening, choose another model or use a shorter dictation.")
    }
  }

  @Test("classified(outputTruncated) unwraps unchanged")
  func classifiedUnwrapsUnchanged() {
    #expect(
      PolishFailureReason.from(LLMError.classified(.outputTruncated)) == .outputTruncated)
  }

}
