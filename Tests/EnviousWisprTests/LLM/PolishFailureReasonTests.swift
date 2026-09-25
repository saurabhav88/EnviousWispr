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
    #expect(reason.composedMessage(provider: .openAI).hasPrefix("AI cleanup skipped: "))
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
    #expect(reason.composedMessage(provider: .openAI).hasPrefix("AI polish failed: "))
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
    let cloudModel = PolishFailureReason.modelUnavailable.composedMessage(provider: .openAI)
    let ollamaModel = PolishFailureReason.modelUnavailable.composedMessage(provider: .ollama)
    #expect(cloudModel.contains("OpenAI model"))
    #expect(ollamaModel.contains("Ollama"))
    #expect(cloudModel != ollamaModel)

    let cloudReach = PolishFailureReason.providerUnreachable.composedMessage(provider: .gemini)
    let ollamaReach = PolishFailureReason.providerUnreachable.composedMessage(provider: .ollama)
    #expect(cloudReach.contains("internet connection"))
    #expect(ollamaReach.contains("Start Ollama"))
    #expect(cloudReach != ollamaReach)
  }

  /// #1914: a 401 from Ollama means the user is signed out of ollama.com, and the
  /// generic line points at an EnviousWispr Settings API key that Ollama has
  /// none of. Frozen as an EXACT composed string, not a `contains`, because the
  /// value of this arm is the specific command it names.
  @Test("Ollama 401 copy names the real signin command, not a Settings key")
  func ollamaSignedOutCopy() {
    let ollama = PolishFailureReason.apiKeyRejected.composedMessage(provider: .ollama)
    #expect(
      ollama
        == "AI polish failed: Ollama isn't signed in. "
        + "Run ollama signin in Terminal, then try again.")
    #expect(ollama.contains("ollama signin"))
    #expect(ollama.contains("Settings") == false)

    // The control, stated for what it actually proves: the cloud arm is BYTE
    // IDENTICAL to before #1914. Deleting the Ollama branch is caught by the
    // three expectations above, not by this one — with the branch gone, Ollama's
    // text would still differ from OpenAI's, because `name` is interpolated. So
    // this line pins the untouched arm; it does not detect the missing branch.
    let cloud = PolishFailureReason.apiKeyRejected.composedMessage(provider: .openAI)
    #expect(
      cloud == "AI polish failed: OpenAI rejected your API key. Check or replace it in Settings.")
  }

  /// #1914: a 403 from Ollama means the model is subscription-gated, measured
  /// 2026-08-01 from `this model requires a subscription`. The generic line
  /// suggests API-access and region checks instead of naming that cause.
  @Test("Ollama 403 copy names the subscription and offers picking another model")
  func ollamaPaidTierCopy() {
    let ollama = PolishFailureReason.accessDenied.composedMessage(provider: .ollama)
    #expect(
      ollama
        == "AI polish failed: that Ollama model requires a subscription. "
        + "Pick another model or check your Ollama plan.")
    #expect(ollama.contains("subscription"))
    #expect(ollama.contains("region") == false)

    // Same control shape as the 401 test: this pins the cloud arm as unchanged.
    // It is the exact-string expectation above that fails if the Ollama branch
    // is deleted, not a comparison between the two.
    let cloud = PolishFailureReason.accessDenied.composedMessage(provider: .gemini)
    #expect(
      cloud
        == "AI polish failed: Gemini denied access. "
        + "Check your provider billing, API access, region, or selected model.")
  }

  @Test("the generic fallback lines read cleanly after their lead-in (no restated lead-in)")
  func genericFallbackCopyTightened() {
    // Founder-approved tightening (2026-06-22): these three compose without
    // repeating the lead-in (no "AI cleanup skipped: AI cleanup took too long").
    #expect(
      PolishFailureReason.timedOut.composedMessage(provider: .openAI)
        == "AI cleanup skipped: OpenAI did not answer in time. Your original text was pasted unchanged."
    )
    // #2884: the generic badRequest sentence now belongs to the non-cloud arms
    // only; the cloud copy is pinned per provider in `badRequestNamesTheProvider`.
    #expect(
      PolishFailureReason.badRequest.composedMessage(provider: .ollama)
        == "AI polish failed: a configuration problem stopped it. Your original text was pasted unchanged."
    )
    #expect(
      PolishFailureReason.unknown.composedMessage(provider: .openAI)
        == "AI polish failed: an unexpected error stopped it. Your original text was pasted unchanged."
    )
  }

  // #2884: a production Gemini 400 was every time a picker-admitted model that
  // cannot polish text. The copy names the provider and the fix for the three
  // key-holding providers; the local and bundled arms keep the generic sentence.
  @Test(
    "badRequest names the provider and points at the model picker for cloud providers",
    arguments: [
      (LLMProvider.gemini, "Gemini"),
      (.openAI, "OpenAI"),
      (.claude, "Claude"),
    ])
  func badRequestNamesTheProvider(provider: LLMProvider, name: String) {
    #expect(
      PolishFailureReason.badRequest.composedMessage(provider: provider)
        == "AI polish failed: \(name) rejected the request. Pick another model in Settings.")
  }

  @Test(
    "badRequest keeps the generic sentence for every non-cloud provider",
    arguments: [
      LLMProvider.ollama, .appleIntelligence, .egOne, .s1Mini, .none,
    ])
  func badRequestStaysGenericOffCloud(provider: LLMProvider) {
    #expect(
      PolishFailureReason.badRequest.composedMessage(provider: provider)
        == "AI polish failed: a configuration problem stopped it. Your original text was pasted unchanged."
    )
  }

  /// #3142: each notice is one whole sentence, so nothing composes it from the tone any more.
  /// The English sentence still opens with the words that match its tone, for every provider.
  @Test("every English notice opens with the words for its tone")
  func englishNoticeOpensWithItsTone() {
    for reason in PolishFailureReason.allCases {
      for provider in LLMProvider.allCases {
        let opening = reason.leadIn == .skipped ? "AI cleanup skipped: " : "AI polish failed: "
        #expect(
          reason.composedMessage(provider: provider).hasPrefix(opening), "\(reason) \(provider)")
      }
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
      !PolishFailureReason.outOfCredits.composedMessage(provider: .openAI).lowercased().contains(
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
    // #1914: either the user has not chosen a model, or we deliberately
    // declined to choose a hosted one for them. A configuration state, not a
    // defect, and the count is what tells us how often the refusal fires.
    .noModelSelected,
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

  /// Five reasons tell the user "AI cleanup skipped" — nothing is broken. Exactly two
  /// of them still page us, and both are OURS despite the reassuring copy:
  ///   - `timedOut` — the deadline it blew is a budget WE chose, so a spike means our
  ///     budget shrank or our prompt ballooned.
  ///   - `apiKeyUnreadable` — we stored a key and then could not read it back. Its
  ///     copy is deliberately identical to `apiKeyMissing` (re-entering the key fixes
  ///     both), but only this one is a defect.
  /// The other three are the user's own situation and are counted only. Pinned so a
  /// future tidy-up cannot collapse the notice and the channel into each other: they
  /// answer different questions — "is the user alarmed?" vs "is this our bug?"
  @Test("the only reassuring-looking reasons that still page us are the two that are ours")
  func onlyOurOwnFailuresAlertAmongSkipNotices() {
    let skipNoticeReasons = PolishFailureReason.allCases.filter { $0.leadIn == .skipped }
    #expect(
      Set(skipNoticeReasons) == [
        .apiKeyMissing, .apiKeyUnreadable, .inputTooLong, .timedOut,
        // #1914: skip tone, deliberately. Declining to arm a hosted model for
        // the user is not a breakage to apologise for. This assertion is the
        // ONLY thing pinning that classification — the pill gets its skip
        // prefix from `ollamaPreflightSkipMessage` directly, so no runtime
        // test can catch a wrong `leadIn` here. Mutation-verified.
        .noModelSelected,
      ])

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
      #expect(
        unreadable.composedMessage(provider: provider)
          == missing.composedMessage(provider: provider))
      // The completion planner keys the skip-vs-hard-failure toast off the notice's tone.
      #expect(unreadable.notice(provider: provider).leadIn == .skipped)
      #expect(
        unreadable.notice(provider: provider).text
          == unreadable.composedMessage(provider: provider))
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

  // MARK: - #3142: every notice, typed out

  /// Every reason and provider's notice, as the pre-catalog code composed it (captured from the
  /// old lead-in + fragment composition and typed out here, so the oracle is independent of the
  /// new whole-sentence code). The tone is checked beside the text: the words carry no state.
  static let englishNotices:
    [(PolishFailureReason, LLMProvider, PolishFailureReason.LeadIn, String)] = [
      (
        .apiKeyMissing, .openAI, .skipped,
        "AI cleanup skipped: no OpenAI API key set yet. Add one in Settings."
      ),
      (
        .apiKeyMissing, .gemini, .skipped,
        "AI cleanup skipped: no Gemini API key set yet. Add one in Settings."
      ),
      (
        .apiKeyMissing, .claude, .skipped,
        "AI cleanup skipped: no Claude API key set yet. Add one in Settings."
      ),
      (
        .apiKeyMissing, .ollama, .skipped,
        "AI cleanup skipped: no Ollama API key set yet. Add one in Settings."
      ),
      (
        .apiKeyMissing, .appleIntelligence, .skipped,
        "AI cleanup skipped: no Apple Intelligence API key set yet. Add one in Settings."
      ),
      (
        .apiKeyMissing, .egOne, .skipped,
        "AI cleanup skipped: no EG-1 API key set yet. Add one in Settings."
      ),
      (
        .apiKeyMissing, .s1Mini, .skipped,
        "AI cleanup skipped: no S1-mini API key set yet. Add one in Settings."
      ),
      (
        .apiKeyMissing, .none, .skipped,
        "AI cleanup skipped: no None API key set yet. Add one in Settings."
      ),
      (
        .apiKeyUnreadable, .openAI, .skipped,
        "AI cleanup skipped: no OpenAI API key set yet. Add one in Settings."
      ),
      (
        .apiKeyUnreadable, .gemini, .skipped,
        "AI cleanup skipped: no Gemini API key set yet. Add one in Settings."
      ),
      (
        .apiKeyUnreadable, .claude, .skipped,
        "AI cleanup skipped: no Claude API key set yet. Add one in Settings."
      ),
      (
        .apiKeyUnreadable, .ollama, .skipped,
        "AI cleanup skipped: no Ollama API key set yet. Add one in Settings."
      ),
      (
        .apiKeyUnreadable, .appleIntelligence, .skipped,
        "AI cleanup skipped: no Apple Intelligence API key set yet. Add one in Settings."
      ),
      (
        .apiKeyUnreadable, .egOne, .skipped,
        "AI cleanup skipped: no EG-1 API key set yet. Add one in Settings."
      ),
      (
        .apiKeyUnreadable, .s1Mini, .skipped,
        "AI cleanup skipped: no S1-mini API key set yet. Add one in Settings."
      ),
      (
        .apiKeyUnreadable, .none, .skipped,
        "AI cleanup skipped: no None API key set yet. Add one in Settings."
      ),
      (
        .apiKeyRejected, .openAI, .failed,
        "AI polish failed: OpenAI rejected your API key. Check or replace it in Settings."
      ),
      (
        .apiKeyRejected, .gemini, .failed,
        "AI polish failed: Gemini rejected your API key. Check or replace it in Settings."
      ),
      (
        .apiKeyRejected, .claude, .failed,
        "AI polish failed: Claude rejected your API key. Check or replace it in Settings."
      ),
      (
        .apiKeyRejected, .ollama, .failed,
        "AI polish failed: Ollama isn't signed in. Run ollama signin in Terminal, then try again."
      ),
      (
        .apiKeyRejected, .appleIntelligence, .failed,
        "AI polish failed: Apple Intelligence rejected your API key. Check or replace it in Settings."
      ),
      (
        .apiKeyRejected, .egOne, .failed,
        "AI polish failed: EG-1 rejected your API key. Check or replace it in Settings."
      ),
      (
        .apiKeyRejected, .s1Mini, .failed,
        "AI polish failed: S1-mini rejected your API key. Check or replace it in Settings."
      ),
      (
        .apiKeyRejected, .none, .failed,
        "AI polish failed: None rejected your API key. Check or replace it in Settings."
      ),
      (
        .accessDenied, .openAI, .failed,
        "AI polish failed: OpenAI denied access. Check your provider billing, API access, region, or selected model."
      ),
      (
        .accessDenied, .gemini, .failed,
        "AI polish failed: Gemini denied access. Check your provider billing, API access, region, or selected model."
      ),
      (
        .accessDenied, .claude, .failed,
        "AI polish failed: Claude denied access. Check your provider billing, API access, region, or selected model."
      ),
      (
        .accessDenied, .ollama, .failed,
        "AI polish failed: that Ollama model requires a subscription. Pick another model or check your Ollama plan."
      ),
      (
        .accessDenied, .appleIntelligence, .failed,
        "AI polish failed: Apple Intelligence denied access. Check your provider billing, API access, region, or selected model."
      ),
      (
        .accessDenied, .egOne, .failed,
        "AI polish failed: EG-1 denied access. Check your provider billing, API access, region, or selected model."
      ),
      (
        .accessDenied, .s1Mini, .failed,
        "AI polish failed: S1-mini denied access. Check your provider billing, API access, region, or selected model."
      ),
      (
        .accessDenied, .none, .failed,
        "AI polish failed: None denied access. Check your provider billing, API access, region, or selected model."
      ),
      (
        .outOfCredits, .openAI, .failed,
        "AI polish failed: your OpenAI account is out of credits. Check your provider billing."
      ),
      (
        .outOfCredits, .gemini, .failed,
        "AI polish failed: your Gemini account is out of credits. Check your provider billing."
      ),
      (
        .outOfCredits, .claude, .failed,
        "AI polish failed: your Claude account is out of credits. Check your provider billing."
      ),
      (
        .outOfCredits, .ollama, .failed,
        "AI polish failed: your Ollama account is out of credits. Check your provider billing."
      ),
      (
        .outOfCredits, .appleIntelligence, .failed,
        "AI polish failed: your Apple Intelligence account is out of credits. Check your provider billing."
      ),
      (
        .outOfCredits, .egOne, .failed,
        "AI polish failed: your EG-1 account is out of credits. Check your provider billing."
      ),
      (
        .outOfCredits, .s1Mini, .failed,
        "AI polish failed: your S1-mini account is out of credits. Check your provider billing."
      ),
      (
        .outOfCredits, .none, .failed,
        "AI polish failed: your None account is out of credits. Check your provider billing."
      ),
      (
        .rateLimited, .openAI, .failed,
        "AI polish failed: too many requests to OpenAI right now. It should work again in a moment."
      ),
      (
        .rateLimited, .gemini, .failed,
        "AI polish failed: too many requests to Gemini right now. It should work again in a moment."
      ),
      (
        .rateLimited, .claude, .failed,
        "AI polish failed: too many requests to Claude right now. It should work again in a moment."
      ),
      (
        .rateLimited, .ollama, .failed,
        "AI polish failed: too many requests to Ollama right now. It should work again in a moment."
      ),
      (
        .rateLimited, .appleIntelligence, .failed,
        "AI polish failed: too many requests to Apple Intelligence right now. It should work again in a moment."
      ),
      (
        .rateLimited, .egOne, .failed,
        "AI polish failed: too many requests to EG-1 right now. It should work again in a moment."
      ),
      (
        .rateLimited, .s1Mini, .failed,
        "AI polish failed: too many requests to S1-mini right now. It should work again in a moment."
      ),
      (
        .rateLimited, .none, .failed,
        "AI polish failed: too many requests to None right now. It should work again in a moment."
      ),
      (
        .rateLimitedOrQuota, .openAI, .failed,
        "AI polish failed: OpenAI hit a rate or quota limit. Wait a moment, or check your OpenAI billing if it keeps happening."
      ),
      (
        .rateLimitedOrQuota, .gemini, .failed,
        "AI polish failed: Gemini hit a rate or quota limit. Wait a moment, or check your Gemini billing if it keeps happening."
      ),
      (
        .rateLimitedOrQuota, .claude, .failed,
        "AI polish failed: Claude hit a rate or quota limit. Wait a moment, or check your Claude billing if it keeps happening."
      ),
      (
        .rateLimitedOrQuota, .ollama, .failed,
        "AI polish failed: Ollama hit a rate or quota limit. Wait a moment, or check your Ollama billing if it keeps happening."
      ),
      (
        .rateLimitedOrQuota, .appleIntelligence, .failed,
        "AI polish failed: Apple Intelligence hit a rate or quota limit. Wait a moment, or check your Apple Intelligence billing if it keeps happening."
      ),
      (
        .rateLimitedOrQuota, .egOne, .failed,
        "AI polish failed: EG-1 hit a rate or quota limit. Wait a moment, or check your EG-1 billing if it keeps happening."
      ),
      (
        .rateLimitedOrQuota, .s1Mini, .failed,
        "AI polish failed: S1-mini hit a rate or quota limit. Wait a moment, or check your S1-mini billing if it keeps happening."
      ),
      (
        .rateLimitedOrQuota, .none, .failed,
        "AI polish failed: None hit a rate or quota limit. Wait a moment, or check your None billing if it keeps happening."
      ),
      (
        .modelUnavailable, .openAI, .failed,
        "AI polish failed: the selected OpenAI model isn't available. Pick another in Settings."
      ),
      (
        .modelUnavailable, .gemini, .failed,
        "AI polish failed: the selected Gemini model isn't available. Pick another in Settings."
      ),
      (
        .modelUnavailable, .claude, .failed,
        "AI polish failed: the selected Claude model isn't available. Pick another in Settings."
      ),
      (
        .modelUnavailable, .ollama, .failed,
        "AI polish failed: that Ollama model isn't downloaded yet. Pull it in Ollama or pick another in Settings."
      ),
      (
        .modelUnavailable, .appleIntelligence, .failed,
        "AI polish failed: the selected Apple Intelligence model isn't available. Pick another in Settings."
      ),
      (
        .modelUnavailable, .egOne, .failed,
        "AI polish failed: the selected EG-1 model isn't available. Pick another in Settings."
      ),
      (
        .modelUnavailable, .s1Mini, .failed,
        "AI polish failed: the selected S1-mini model isn't available. Pick another in Settings."
      ),
      (
        .modelUnavailable, .none, .failed,
        "AI polish failed: the selected None model isn't available. Pick another in Settings."
      ),
      (
        .noModelSelected, .openAI, .skipped,
        "AI cleanup skipped: no polish model is selected. Pick one in Settings."
      ),
      (
        .noModelSelected, .gemini, .skipped,
        "AI cleanup skipped: no polish model is selected. Pick one in Settings."
      ),
      (
        .noModelSelected, .claude, .skipped,
        "AI cleanup skipped: no polish model is selected. Pick one in Settings."
      ),
      (
        .noModelSelected, .ollama, .skipped,
        "AI cleanup skipped: no polish model is selected. Pick one in Settings."
      ),
      (
        .noModelSelected, .appleIntelligence, .skipped,
        "AI cleanup skipped: no polish model is selected. Pick one in Settings."
      ),
      (
        .noModelSelected, .egOne, .skipped,
        "AI cleanup skipped: no polish model is selected. Pick one in Settings."
      ),
      (
        .noModelSelected, .s1Mini, .skipped,
        "AI cleanup skipped: no polish model is selected. Pick one in Settings."
      ),
      (
        .noModelSelected, .none, .skipped,
        "AI cleanup skipped: no polish model is selected. Pick one in Settings."
      ),
      (
        .inputTooLong, .openAI, .skipped,
        "AI cleanup skipped: this dictation is too long for the selected model. Try a shorter one or a larger model in Settings."
      ),
      (
        .inputTooLong, .gemini, .skipped,
        "AI cleanup skipped: this dictation is too long for the selected model. Try a shorter one or a larger model in Settings."
      ),
      (
        .inputTooLong, .claude, .skipped,
        "AI cleanup skipped: this dictation is too long for the selected model. Try a shorter one or a larger model in Settings."
      ),
      (
        .inputTooLong, .ollama, .skipped,
        "AI cleanup skipped: this dictation is too long for the selected model. Try a shorter one or a larger model in Settings."
      ),
      (
        .inputTooLong, .appleIntelligence, .skipped,
        "AI cleanup skipped: this dictation is too long for the selected model. Try a shorter one or a larger model in Settings."
      ),
      (
        .inputTooLong, .egOne, .skipped,
        "AI cleanup skipped: this dictation is too long for the selected model. Try a shorter one or a larger model in Settings."
      ),
      (
        .inputTooLong, .s1Mini, .skipped,
        "AI cleanup skipped: this dictation is too long for the selected model. Try a shorter one or a larger model in Settings."
      ),
      (
        .inputTooLong, .none, .skipped,
        "AI cleanup skipped: this dictation is too long for the selected model. Try a shorter one or a larger model in Settings."
      ),
      (
        .contentBlocked, .openAI, .failed,
        "AI polish failed: OpenAI blocked this text. Your original was pasted unchanged."
      ),
      (
        .contentBlocked, .gemini, .failed,
        "AI polish failed: Gemini blocked this text. Your original was pasted unchanged."
      ),
      (
        .contentBlocked, .claude, .failed,
        "AI polish failed: Claude blocked this text. Your original was pasted unchanged."
      ),
      (
        .contentBlocked, .ollama, .failed,
        "AI polish failed: Ollama blocked this text. Your original was pasted unchanged."
      ),
      (
        .contentBlocked, .appleIntelligence, .failed,
        "AI polish failed: Apple Intelligence blocked this text. Your original was pasted unchanged."
      ),
      (
        .contentBlocked, .egOne, .failed,
        "AI polish failed: EG-1 blocked this text. Your original was pasted unchanged."
      ),
      (
        .contentBlocked, .s1Mini, .failed,
        "AI polish failed: S1-mini blocked this text. Your original was pasted unchanged."
      ),
      (
        .contentBlocked, .none, .failed,
        "AI polish failed: None blocked this text. Your original was pasted unchanged."
      ),
      (
        .providerUnreachable, .openAI, .failed,
        "AI polish failed: couldn't reach OpenAI. Check your internet connection, VPN, or proxy."
      ),
      (
        .providerUnreachable, .gemini, .failed,
        "AI polish failed: couldn't reach Gemini. Check your internet connection, VPN, or proxy."
      ),
      (
        .providerUnreachable, .claude, .failed,
        "AI polish failed: couldn't reach Claude. Check your internet connection, VPN, or proxy."
      ),
      (
        .providerUnreachable, .ollama, .failed,
        "AI polish failed: Ollama isn't reachable. Start Ollama and try again."
      ),
      (
        .providerUnreachable, .appleIntelligence, .failed,
        "AI polish failed: couldn't reach Apple Intelligence. Check your internet connection, VPN, or proxy."
      ),
      (
        .providerUnreachable, .egOne, .failed,
        "AI polish failed: couldn't reach EG-1. Check your internet connection, VPN, or proxy."
      ),
      (
        .providerUnreachable, .s1Mini, .failed,
        "AI polish failed: couldn't reach S1-mini. Check your internet connection, VPN, or proxy."
      ),
      (
        .providerUnreachable, .none, .failed,
        "AI polish failed: couldn't reach None. Check your internet connection, VPN, or proxy."
      ),
      (
        .providerServerError, .openAI, .failed,
        "AI polish failed: OpenAI is having problems right now. Try again shortly."
      ),
      (
        .providerServerError, .gemini, .failed,
        "AI polish failed: Gemini is having problems right now. Try again shortly."
      ),
      (
        .providerServerError, .claude, .failed,
        "AI polish failed: Claude is having problems right now. Try again shortly."
      ),
      (
        .providerServerError, .ollama, .failed,
        "AI polish failed: Ollama is having problems right now. Try again shortly."
      ),
      (
        .providerServerError, .appleIntelligence, .failed,
        "AI polish failed: Apple Intelligence is having problems right now. Try again shortly."
      ),
      (
        .providerServerError, .egOne, .failed,
        "AI polish failed: EG-1 is having problems right now. Try again shortly."
      ),
      (
        .providerServerError, .s1Mini, .failed,
        "AI polish failed: S1-mini is having problems right now. Try again shortly."
      ),
      (
        .providerServerError, .none, .failed,
        "AI polish failed: None is having problems right now. Try again shortly."
      ),
      (
        .badRequest, .openAI, .failed,
        "AI polish failed: OpenAI rejected the request. Pick another model in Settings."
      ),
      (
        .badRequest, .gemini, .failed,
        "AI polish failed: Gemini rejected the request. Pick another model in Settings."
      ),
      (
        .badRequest, .claude, .failed,
        "AI polish failed: Claude rejected the request. Pick another model in Settings."
      ),
      (
        .badRequest, .ollama, .failed,
        "AI polish failed: a configuration problem stopped it. Your original text was pasted unchanged."
      ),
      (
        .badRequest, .appleIntelligence, .failed,
        "AI polish failed: a configuration problem stopped it. Your original text was pasted unchanged."
      ),
      (
        .badRequest, .egOne, .failed,
        "AI polish failed: a configuration problem stopped it. Your original text was pasted unchanged."
      ),
      (
        .badRequest, .s1Mini, .failed,
        "AI polish failed: a configuration problem stopped it. Your original text was pasted unchanged."
      ),
      (
        .badRequest, .none, .failed,
        "AI polish failed: a configuration problem stopped it. Your original text was pasted unchanged."
      ),
      (
        .emptyResponse, .openAI, .failed,
        "AI polish failed: OpenAI returned no cleanup text. Try again."
      ),
      (
        .emptyResponse, .gemini, .failed,
        "AI polish failed: Gemini returned no cleanup text. Try again."
      ),
      (
        .emptyResponse, .claude, .failed,
        "AI polish failed: Claude returned no cleanup text. Try again."
      ),
      (
        .emptyResponse, .ollama, .failed,
        "AI polish failed: Ollama returned no cleanup text. Try again."
      ),
      (
        .emptyResponse, .appleIntelligence, .failed,
        "AI polish failed: Apple Intelligence returned no cleanup text. Try again."
      ),
      (
        .emptyResponse, .egOne, .failed,
        "AI polish failed: EG-1 returned no cleanup text. Try again."
      ),
      (
        .emptyResponse, .s1Mini, .failed,
        "AI polish failed: S1-mini returned no cleanup text. Try again."
      ),
      (
        .emptyResponse, .none, .failed,
        "AI polish failed: None returned no cleanup text. Try again."
      ),
      (
        .timedOut, .openAI, .skipped,
        "AI cleanup skipped: OpenAI did not answer in time. Your original text was pasted unchanged."
      ),
      (
        .timedOut, .gemini, .skipped,
        "AI cleanup skipped: Gemini did not answer in time. Your original text was pasted unchanged."
      ),
      (
        .timedOut, .claude, .skipped,
        "AI cleanup skipped: Claude did not answer in time. Your original text was pasted unchanged."
      ),
      (
        .timedOut, .ollama, .skipped,
        "AI cleanup skipped: Ollama did not answer in time. Your original text was pasted unchanged."
      ),
      (
        .timedOut, .appleIntelligence, .skipped,
        "AI cleanup skipped: Apple Intelligence did not answer in time. Your original text was pasted unchanged."
      ),
      (
        .timedOut, .egOne, .skipped,
        "AI cleanup skipped: EG-1 did not answer in time. Your original text was pasted unchanged."
      ),
      (
        .timedOut, .s1Mini, .skipped,
        "AI cleanup skipped: S1-mini did not answer in time. Your original text was pasted unchanged."
      ),
      (
        .timedOut, .none, .skipped,
        "AI cleanup skipped: None did not answer in time. Your original text was pasted unchanged."
      ),
      (
        .outputTruncated, .openAI, .failed,
        "AI polish failed: OpenAI ended the response before cleanup finished. EnviousWispr kept your complete original text instead. If this keeps happening, choose another model or use a shorter dictation."
      ),
      (
        .outputTruncated, .gemini, .failed,
        "AI polish failed: Gemini ended the response before cleanup finished. EnviousWispr kept your complete original text instead. If this keeps happening, choose another model or use a shorter dictation."
      ),
      (
        .outputTruncated, .claude, .failed,
        "AI polish failed: Claude ended the response before cleanup finished. EnviousWispr kept your complete original text instead. If this keeps happening, choose another model or use a shorter dictation."
      ),
      (
        .outputTruncated, .ollama, .failed,
        "AI polish failed: Ollama ended the response before cleanup finished. EnviousWispr kept your complete original text instead. If this keeps happening, choose another model or use a shorter dictation."
      ),
      (
        .outputTruncated, .appleIntelligence, .failed,
        "AI polish failed: Apple Intelligence ended the response before cleanup finished. EnviousWispr kept your complete original text instead. If this keeps happening, choose another model or use a shorter dictation."
      ),
      (
        .outputTruncated, .egOne, .failed,
        "AI polish failed: EG-1 ended the response before cleanup finished. EnviousWispr kept your complete original text instead. If this keeps happening, choose another model or use a shorter dictation."
      ),
      (
        .outputTruncated, .s1Mini, .failed,
        "AI polish failed: S1-mini ended the response before cleanup finished. EnviousWispr kept your complete original text instead. If this keeps happening, choose another model or use a shorter dictation."
      ),
      (
        .outputTruncated, .none, .failed,
        "AI polish failed: None ended the response before cleanup finished. EnviousWispr kept your complete original text instead. If this keeps happening, choose another model or use a shorter dictation."
      ),
      (
        .unknown, .openAI, .failed,
        "AI polish failed: an unexpected error stopped it. Your original text was pasted unchanged."
      ),
      (
        .unknown, .gemini, .failed,
        "AI polish failed: an unexpected error stopped it. Your original text was pasted unchanged."
      ),
      (
        .unknown, .claude, .failed,
        "AI polish failed: an unexpected error stopped it. Your original text was pasted unchanged."
      ),
      (
        .unknown, .ollama, .failed,
        "AI polish failed: an unexpected error stopped it. Your original text was pasted unchanged."
      ),
      (
        .unknown, .appleIntelligence, .failed,
        "AI polish failed: an unexpected error stopped it. Your original text was pasted unchanged."
      ),
      (
        .unknown, .egOne, .failed,
        "AI polish failed: an unexpected error stopped it. Your original text was pasted unchanged."
      ),
      (
        .unknown, .s1Mini, .failed,
        "AI polish failed: an unexpected error stopped it. Your original text was pasted unchanged."
      ),
      (
        .unknown, .none, .failed,
        "AI polish failed: an unexpected error stopped it. Your original text was pasted unchanged."
      ),
    ]

  @Test("every reason and provider keeps its English notice and its tone")
  func everyNoticeKeepsItsEnglish() {
    // Every reason and provider pair appears exactly once: a count alone would let one pair be
    // duplicated while another is missing.
    let expectedPairs = Set(
      PolishFailureReason.allCases.flatMap { reason in
        LLMProvider.allCases.map { "\(reason.rawValue)|\($0.rawValue)" }
      })
    let actualPairs = Set(Self.englishNotices.map { "\($0.0.rawValue)|\($0.1.rawValue)" })
    #expect(actualPairs == expectedPairs)
    #expect(Self.englishNotices.count == expectedPairs.count)
    for (reason, provider, leadIn, text) in Self.englishNotices {
      #expect(reason.composedMessage(provider: provider) == text, "\(reason) \(provider)")
      #expect(reason.notice(provider: provider).leadIn == leadIn, "\(reason) \(provider)")
      #expect(reason.notice(provider: provider).text == text, "\(reason) \(provider)")
    }
  }

  @Test("the three Ollama preflight notices keep their English and are skips")
  func preflightNoticesKeepTheirEnglish() {
    #expect(
      PolishFailureReason.modelUnavailable.ollamaPreflightSkipMessage
        == "AI cleanup skipped: the selected Ollama model isn't installed. Download it or pick another in Settings → AI Polish."
    )
    #expect(PolishFailureReason.modelUnavailable.ollamaPreflightSkipNotice?.leadIn == .skipped)
    #expect(
      PolishFailureReason.noModelSelected.ollamaPreflightSkipMessage
        == "AI cleanup skipped: no polish model selected. Pick one in Settings → AI Polish.")
    #expect(PolishFailureReason.noModelSelected.ollamaPreflightSkipNotice?.leadIn == .skipped)
    #expect(
      PolishFailureReason.providerUnreachable.ollamaPreflightSkipMessage
        == "AI cleanup skipped: Ollama isn't running. Start it in Settings → AI Polish.")
    #expect(PolishFailureReason.providerUnreachable.ollamaPreflightSkipNotice?.leadIn == .skipped)
    let others = PolishFailureReason.allCases.filter {
      ![.providerUnreachable, .modelUnavailable, .noModelSelected].contains($0)
    }
    #expect(others.allSatisfy { $0.ollamaPreflightSkipMessage == nil })
  }
}
