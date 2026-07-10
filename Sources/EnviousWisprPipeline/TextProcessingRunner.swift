import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprPostProcessing
import EnviousWisprServices
import Foundation

/// Result of running the text processing chain.
@MainActor
internal struct TextProcessingRunResult {
  let context: TextProcessingContext
  /// Error message from polish step failure, if any. Surfaced to user as lastPolishError.
  let polishError: String?
}

/// Runs the post-ASR text processing chain: word correction -> filler removal -> LLM polish.
///
/// Does NOT own step instances. Steps are passed in by the pipeline, which retains
/// ownership for PipelineSettingsSync mutation.
/// The runner owns only the execution algorithm: ordering, timeout, cancellation,
/// failure continuation (heart & limbs), and CORRECTION_DEBUG logging.
///
/// Phase G1+G2: error-surface dispatch reads `step.errorSurfacePolicy` instead
/// of matching `step.name == "LLM Polish"`, and the log sink is injectable via
/// `PipelineLogging` so tests can verify side effects without disk reads.
@MainActor
internal final class TextProcessingRunner {

  /// Per-step timeout-executor seam (#784, 2026-05-18). Production default
  /// delegates to `withThrowingTimeout`; tests inject a deterministic fake
  /// that decides per call whether to run the operation or throw
  /// `TimeoutError`. Specialized to `TextProcessingContext` because the
  /// runner only ever times out step operations of that return type.
  ///
  /// REVIEWED_OK(#827): this pre-existing guard is covered by the injected
  /// executor tests and surfaces `TimeoutError` into the normal limb-failed
  /// continuation path.
  typealias TimeoutExecutor = @MainActor (
    Double,
    @escaping @MainActor () async throws -> TextProcessingContext
  ) async throws -> TextProcessingContext

  /// Telemetry seam (#945) mirroring `timeoutExecutor`. Production default
  /// delegates to `SentryBreadcrumb.captureError`; `RecoveryTextProcessor`
  /// injects a no-op so crash-recovery polish failures stay silent, and tests
  /// inject a spy. Fire-and-forget / non-throwing, so a capture can never break
  /// the limb-failure continuation (heart & limbs). The trailing `String?` is the
  /// fingerprint discriminator (#945): `.classified(reason)` bridges every reason
  /// to one `NSError` code, so the reason tag must split the Sentry issue.
  typealias CaptureError = @MainActor (
    any Error, SentryBreadcrumb.ErrorCategory, String, [String: Any]?, [String: String], String?
  ) -> Void

  /// Durable, non-alerting record of a LIVE attempted-polish failure (#1446),
  /// mirroring `captureError`. Production leaves a Sentry breadcrumb and emits the
  /// counted `llm.polish_failed` event; `RecoveryTextProcessor` injects a no-op
  /// (the same reason `captureError` is no-op'd there — this is a live-only
  /// metric, #945); tests inject a spy. Fire-and-forget / non-throwing, so
  /// telemetry can never break the limb-failure continuation (heart & limbs).
  ///
  /// Fires on EVERY live attempted-polish failure, both channels — unlike
  /// `captureError`, which fires only for the regression-capable subset. That
  /// asymmetry is what lets a test assert "the durable record exists AND no alert
  /// fired." Parameters: provider, model, reason tag, isTimeout.
  typealias RecordPolishFailed = @MainActor (String, String, String, Bool) -> Void

  /// Durable record of a LIVE polish that was never ATTEMPTED — the AFM
  /// context-window skips (#1055), EG-1 bypasses (#1271), and the Ollama readiness
  /// preflight (#1305). Parameters: provider, skip reason.
  typealias RecordPolishSkipped = @MainActor (String, String) -> Void

  /// Every POLISH telemetry seam the runner owns, as ONE value (#1446).
  ///
  /// The point is `silent`. Crash recovery must emit no polish telemetry (#945: a
  /// live-only metric), and when the runner had a single `captureError` seam the
  /// caller expressed that by passing one no-op closure. Adding a second seam
  /// quietly broke that: a caller could silence one and leave the other live, with
  /// nothing to catch it. Bundling them means `silent` is the single place that
  /// answers "what does silence mean," and the memberwise initializer forces any
  /// FUTURE seam to be named there before this file compiles.
  ///
  /// So the bug class is not tested for; it is unwritable. (`recordPolishSkipped`
  /// is the third seam, found by the cloud reviewer on PR #1460 while it was still
  /// calling `TelemetryService.shared` directly — proof the trap is real.)
  ///
  /// NOT in here, deliberately: `customWordsTimeoutFired` (#657). That is a
  /// custom-words performance metric, not polish telemetry, and #945's live-only
  /// decision is scoped to polish. A recovered take whose word-correction step
  /// blows its cap SHOULD still report it.
  struct TelemetrySeams {
    let captureError: CaptureError
    let recordPolishFailed: RecordPolishFailed
    let recordPolishSkipped: RecordPolishSkipped

    /// Production: alerting Sentry events plus the counted `llm.polish_*` events.
    static let live = TelemetrySeams(
      captureError: { error, category, stage, extra, tags, fingerprintDetail in
        SentryBreadcrumb.captureError(
          error, category: category, stage: stage, extra: extra, tags: tags,
          fingerprintDetail: fingerprintDetail)
      },
      recordPolishFailed: { provider, model, reason, isTimeout in
        // Sibling of LLMPolishStep's "LLM polish started" / "LLM polish completed"
        // crumbs; the distinct wording keeps this trail entry legible next to
        // theirs (they also carry `model`).
        SentryBreadcrumb.add(
          stage: "polish",
          message: "LLM polish attempt failed (\(reason)); continuing with deterministic text",
          data: ["provider": provider, "model": model, "is_timeout": isTimeout]
        )
        TelemetryService.shared.polishFailed(
          provider: provider, model: model, reason: reason, isTimeout: isTimeout)
      },
      recordPolishSkipped: { provider, reason in
        TelemetryService.shared.polishSkipped(provider: provider, reason: reason)
      })

    /// Crash recovery (#945, #1446): a recovered take that fails to polish still
    /// returns its `polishError`, but the RUNNER reports nothing — no
    /// `polish_provider_failed` Sentry event, no attempt-failed breadcrumb, no
    /// `llm.polish_failed`, no `llm.polish_skipped`. Polish telemetry is a
    /// LIVE-dictation metric.
    ///
    /// SCOPE, precisely: this silences the three seams the RUNNER owns. It cannot
    /// reach `LLMPolishStep`'s own five emitters (`limbFailureObserved`, the
    /// "LLM polish started" / "completed" breadcrumbs, its `captureError`, and
    /// `captureAFMPolishError`), which fire from inside the step on a recovered
    /// take exactly as they do live. Whether recovery should silence those too is a
    /// separate question with a different owner — tracked in #1461, not papered
    /// over here. (Cloud review of PR #1460 caught the earlier version of this
    /// comment claiming recovery emitted "no Sentry event, no breadcrumb"; it does.)
    static let silent = TelemetrySeams(
      captureError: { _, _, _, _, _, _ in },
      recordPolishFailed: { _, _, _, _ in },
      recordPolishSkipped: { _, _ in })
  }

  private let logger: any PipelineLogging
  private let timeoutExecutor: TimeoutExecutor
  private let captureError: CaptureError
  private let recordPolishFailed: RecordPolishFailed
  private let recordPolishSkipped: RecordPolishSkipped

  init(
    logger: any PipelineLogging = AppLoggerAdapter(),
    telemetry: TelemetrySeams = .live,
    timeoutExecutor: @escaping TimeoutExecutor = { seconds, op in
      // nonisolated(unsafe) bridges @MainActor `op` to withThrowingTimeout's
      // @Sendable contract. Safety: op is @MainActor and its return value
      // (TextProcessingContext) is Sendable, so when op runs inside the
      // task group's child task and returns to the parent, the result
      // crosses isolation safely. This is the SOLE nonisolated(unsafe) in the
      // runner: it quarantines the @MainActor-to-@Sendable impedance inside this
      // executor seam (swift-patterns timing-seam-shapes) rather than widening
      // Core's withThrowingTimeout. (#827 PR-8)
      nonisolated(unsafe) let unsafeOp = op
      return try await withThrowingTimeout(seconds: seconds) {
        try await unsafeOp()
      }
    }
  ) {
    self.logger = logger
    self.captureError = telemetry.captureError
    self.recordPolishFailed = telemetry.recordPolishFailed
    self.recordPolishSkipped = telemetry.recordPolishSkipped
    self.timeoutExecutor = timeoutExecutor
  }

  func run(
    rawText: String,
    language: String?,
    targetAppName: String?,
    steps: [any TextProcessingStep]
  ) async throws -> TextProcessingRunResult {
    var context = TextProcessingContext(text: rawText, language: language)
    context.targetAppName = targetAppName
    var polishError: String?

    let logger = self.logger
    Task {
      await logger.log(
        "CORRECTION_DEBUG [RAW ASR] \(rawText)",
        level: .info, category: "CorrectionDebug"
      )
    }

    for step in steps where step.isEnabled {
      let stepName = step.name
      let input = context
      let stepStart = CFAbsoluteTimeGetCurrent()
      let budgetSeconds =
        Double(step.maxDuration.components.seconds)
        + Double(step.maxDuration.components.attoseconds) / 1e18
      // #1055: snapshot the polish provider BEFORE the await. `LLMPolishStep.
      // llmProvider` is a mutable @MainActor property that PipelineSettingsSync
      // can change while `process()` is in flight; reading it in the catch block
      // (after the timeout suspension) would misclassify the timeout if the user
      // switched providers mid-polish. Snapshotting here mirrors the step's own
      // entry snapshot of `provider` and the `stepName` snapshot above.
      let polishProviderAtStart = (step as? LLMPolishStep)?.llmProvider
      // #945: snapshot the attempted model alongside the provider, pre-await. On
      // failure `context.llmModel` is never stamped (set only on success,
      // LLMPolishStep.swift), so the step snapshot is the only reliable source of
      // the model the failed attempt actually used.
      let polishModelAtStart = (step as? LLMPolishStep)?.llmModel
      do {
        context = try await timeoutExecutor(budgetSeconds) {
          try await step.process(input)
        }
        let stepMs = (CFAbsoluteTimeGetCurrent() - stepStart) * 1000
        let inputText = input.polishedText ?? input.text
        let outputText = context.polishedText ?? context.text
        let changed = inputText != outputText
        Task {
          await logger.log(
            "\(stepName) completed in \(String(format: "%.1f", stepMs))ms (budget: \(String(format: "%.0f", budgetSeconds * 1000))ms)",
            level: .info, category: "PipelineTiming"
          )
          if changed {
            await logger.log(
              "CORRECTION_DEBUG [\(stepName)] IN:  \(inputText)",
              level: .info, category: "CorrectionDebug"
            )
            await logger.log(
              "CORRECTION_DEBUG [\(stepName)] OUT: \(outputText)",
              level: .info, category: "CorrectionDebug"
            )
          } else {
            await logger.log(
              "CORRECTION_DEBUG [\(stepName)] no change",
              level: .info, category: "CorrectionDebug"
            )
          }
        }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        let stepMs = (CFAbsoluteTimeGetCurrent() - stepStart) * 1000
        let isTimeout = error is TimeoutError
        // #1055: AFM context-window overflow is a clean skip (dictation too long
        // for the on-device model), not a failure — raw deterministically-cleaned
        // text passes through and no "AI polish failed" is surfaced.
        let contextWindowSkip = error as? AFMContextWindowExceeded
        // #1055: an Apple Intelligence polish that TIMES OUT (the on-device model
        // stalling on a long or runaway dictation) is handled exactly like a
        // context-window skip — silent raw fallback, not an "AI polish failed"
        // error. On-device polish of long input is known-flaky and the clean
        // deterministic text is the right thing to ship. Scoped to the
        // appleIntelligence provider ONLY: cloud-provider timeouts still surface
        // (they signal a transient network issue the user should see).
        let isAppleIntelligencePolishTimeout =
          isTimeout && polishProviderAtStart == .appleIntelligence
        // #1271: an EG-1 polish timeout (the local 4B model on a very long
        // dictation) is the same class of silent skip as the AFM timeout —
        // raw deterministically-cleaned text ships, no "AI polish failed".
        // Cloud-provider timeouts still surface (transient network signal).
        let isEGOnePolishTimeout = isTimeout && polishProviderAtStart == .egOne
        // #1305: the Ollama readiness preflight found local polish not usable
        // (server down / model missing) BEFORE any attempt started. This is
        // the third, SURFACED-SKIP class between Failure and Bypass: user
        // notice YES (pinned skipped-tone copy), Sentry capture NO (an
        // expected, non-crashing state the user can sit in for hours —
        // per-dictation error events would flood the tracker without signal),
        // PostHog `llm.polish_skipped` YES. Mid-flight failures on a running
        // server (post-preflight races, 5xx) keep the full surfaced-failure
        // path below. Locked by the adversarial tests in
        // TextProcessingRunnerCaptureTests.
        var localPolishSkipReason: PolishFailureReason?
        if let llmError = error as? LLMError,
          case .localPolishNotReady(let notReady) = llmError
        {
          localPolishSkipReason = notReady
        }
        let reason: String
        if isAppleIntelligencePolishTimeout {
          reason =
            "skipped: on-device AI polish timed out on a long dictation, using deterministic text"
        } else if isEGOnePolishTimeout {
          reason =
            "skipped: EG-1 polish timed out on a long dictation, using deterministic text"
        } else if isTimeout {
          reason = "timed out"
        } else if let cw = contextWindowSkip {
          reason = "skipped: too long for on-device AI polish (\(cw.stage.rawValue))"
        } else if let notReady = localPolishSkipReason {
          reason = "skipped: Ollama polish not ready (\(notReady.telemetryTag)), using raw text"
        } else {
          reason = "failed: \(error.localizedDescription)"
        }
        // Apple Intelligence skips that degrade quietly to raw text instead of
        // an "AI polish failed" pill: per-request language gates (unsupported
        // input language, output-language drift) AND the PERMANENT
        // provider-incapable case (#1080 — pre-macOS-26 / Apple Intelligence
        // switched off / ineligible hardware / not compiled in).
        // `frameworkUnavailable` is thrown ONLY by AppleIntelligenceConnector
        // for those permanent states and fires on EVERY dictation for such a
        // Mac, so surfacing it nags a user who cannot fix it from the live
        // path. Log and continue with raw text; do not set `polishError`,
        // which would surface as "AI polish failed" in the UI.
        // Contract: `frameworkUnavailable` is the PERMANENT "this Mac or build
        // cannot run Apple Intelligence" state. Every TRANSIENT or actionable
        // outage MUST keep surfacing and stays OUT of this set —
        // `modelNotReady` (model downloading / org-restricted),
        // `providerUnavailable` (Ollama down), `requestFailed` (cloud 5xx),
        // `invalidAPIKey` — locked by the adversarial tests in
        // TextProcessingRunnerTests.
        // #1271: EVERY `egOneSkipped` reason joins the silent set — the
        // first-party local limb degrades quietly to deterministic text
        // (not ready / download pending / crashed / input too long), same
        // contract as the AFM family above. Locked by the adversarial
        // tests in TextProcessingRunnerTests.
        let isSilentPolishSkip: Bool
        var egOneSkipReason: String?
        if let llmError = error as? LLMError {
          switch llmError {
          case .unsupportedInputLanguage, .outputLanguageDrift, .frameworkUnavailable:
            isSilentPolishSkip = true
          case .egOneSkipped(let skipReason):
            isSilentPolishSkip = true
            egOneSkipReason = skipReason.rawValue
          default:
            isSilentPolishSkip = false
          }
        } else {
          isSilentPolishSkip = false
        }
        // #945: a raw `URLError.cancelled` from a torn-down request is not a real
        // failure — never surface a notice or fire a capture for it. Swift
        // `CancellationError` is already short-circuited above
        // (`catch is CancellationError`); this covers the URL-loading variant.
        let isCancellationLike = (error as? URLError)?.code == .cancelled
        if step.errorSurfacePolicy == .surface, let skipReason = localPolishSkipReason {
          // #1305 surfaced skip: set the pinned skipped-tone notice, fire NO
          // Sentry capture (that is the point of the class). The composed
          // fallback covers a defensive future reason without pinned copy.
          polishError =
            skipReason.ollamaPreflightSkipMessage
            ?? skipReason.composedMessage(provider: .ollama)
        } else if step.errorSurfacePolicy == .surface && !isSilentPolishSkip
          && contextWindowSkip == nil && !isAppleIntelligencePolishTimeout
          && !isEGOnePolishTimeout
          && !isCancellationLike
        {
          let model = polishModelAtStart ?? "unknown"
          if let provider = polishProviderAtStart, provider != .appleIntelligence {
            // Cloud (OpenAI/Gemini) or local (Ollama): classify the specific
            // reason once, then feed it into BOTH the self-contained on-screen
            // notice and the telemetry reason tag (#945). Both emits are
            // fire-and-forget; the raw transcript/prompt/provider-body never
            // leave the device (the reason set is closed and content-free).
            let reason = PolishFailureReason.from(error)
            polishError = reason.composedMessage(provider: provider)
            // #1446: EVERY attempted-and-failed polish gets a durable counted
            // record, whatever its channel. Sentry alerting is the interrupting
            // SUBSET below, not the record itself.
            recordPolishFailed(provider.rawValue, model, reason.telemetryTag, isTimeout)
            // #1446: alert only where a spike could plausibly mean WE regressed.
            // A user out of credits, over quota, with no key, or with Ollama shut
            // down is not a defect: those reasons are counted, never paged. The
            // reason owns this policy (`telemetryChannel`); the runner only reads
            // it. Locked by the (reason x provider) matrix test.
            if reason.telemetryChannel(provider: provider) == .alertingSentryError {
              captureError(
                error,
                .polishProviderFailed,
                "polish",
                [
                  "provider": provider.rawValue,
                  "model": model,
                  "is_timeout": isTimeout,
                ],
                [
                  "polish.error_case": reason.telemetryTag,
                  "polish.provider": provider.rawValue,
                  "polish.is_timeout": isTimeout ? "true" : "false",
                ],
                // Split the Sentry issue per reason: `.classified` bridges every
                // reason to one NSError code, so the tag alone would merge them.
                reason.telemetryTag
              )
            }
          } else if polishProviderAtStart == .appleIntelligence {
            // Apple Intelligence: preserve today's exact wording byte-for-byte.
            // The view now renders `polishError` verbatim, so the runner owns the
            // "AI polish failed:" prefix here. AFM generation failures are
            // captured at the polish step, so no Sentry capture fires here.
            polishError = "AI polish failed: " + error.localizedDescription
            // #1446: the durable count MUST still cover this arm. An AFM success
            // emits `llm.polish_completed`, so omitting its failures would leave
            // `llm.polish_failed` unable to partition live polish outcomes and
            // would undercount the on-device failure rate. Only the ALERTING
            // channel is owned elsewhere (the step's `captureAFMPolishError`);
            // the count is ours. Silent AFM skips never reach here — they are
            // excluded by `isSilentPolishSkip` / `contextWindowSkip` /
            // `isAppleIntelligencePolishTimeout` above.
            recordPolishFailed(
              LLMProvider.appleIntelligence.rawValue, model,
              PolishFailureReason.from(error).telemetryTag, isTimeout)
          } else {
            // No polish-provider snapshot: a non-LLMPolishStep surfacing step
            // (only reachable in tests; production's sole `.surface` step is
            // LLMPolishStep). Preserve the legacy raw message; no capture.
            polishError = error.localizedDescription
          }
        }
        // #1055: emit a dedicated skip event so we can measure how often long
        // dictations bypass on-device polish — input the future 1-hour-recording
        // work needs. All three reasons share the `context_window_` prefix so a
        // single analytics query captures every AFM-long-dictation skip mode:
        // predicted (preflight), caught (generation overflow), timeout (stall).
        if let cw = contextWindowSkip {
          let skipReason =
            cw.stage == .predicted ? "context_window_predicted" : "context_window_caught"
          recordPolishSkipped(LLMProvider.appleIntelligence.rawValue, skipReason)
        } else if isAppleIntelligencePolishTimeout {
          recordPolishSkipped(LLMProvider.appleIntelligence.rawValue, "context_window_timeout")
        } else if isEGOnePolishTimeout {
          // #1271: one `local_polish_` prefix family for every EG-1 skip mode.
          recordPolishSkipped(LLMProvider.egOne.rawValue, "local_polish_timeout")
        } else if let egOneSkipReason {
          recordPolishSkipped(LLMProvider.egOne.rawValue, egOneSkipReason)
        } else if let skipReason = localPolishSkipReason?.ollamaPreflightSkipTelemetryReason {
          // #1305: preflight skips ride the same lightweight `local_polish_`
          // reason family as EG-1 — the observability split between "preflight
          // said not ready" (here) and "mid-flight failure on a running
          // server" (the capture path above) falls out of the reason strings.
          recordPolishSkipped(LLMProvider.ollama.rawValue, skipReason)
        }
        // #657 (2026-05-05): emit cap-trip telemetry when WordCorrectionStep
        // exceeds its 3s `maxDuration`. The step's result was discarded; raw
        // text passes through. The runner is the right owner because this is
        // where the actual discard happens.
        let logCapMessage: String
        if isTimeout, stepName == "Word Correction",
          let wcStep = step as? WordCorrectionStep
        {
          let capMs = budgetSeconds * 1000
          let inputChars = input.text.count
          TelemetryService.shared.customWordsTimeoutFired(
            vocabSize: wcStep.correctorVocabulary.terms.count,
            elapsedMs: stepMs,
            inputChars: inputChars
          )
          logCapMessage =
            "\(stepName) timed out at \(String(format: "%.0f", capMs))ms cap after \(String(format: "%.1f", stepMs))ms — skipping"
        } else {
          logCapMessage =
            "\(stepName) \(reason) after \(String(format: "%.1f", stepMs))ms — skipping"
        }
        Task {
          await logger.log(logCapMessage, level: .info, category: "TextProcessing")
        }
        // Heart & Limbs: limb failed, continue with input text
      }
    }
    return TextProcessingRunResult(context: context, polishError: polishError)
  }
}
