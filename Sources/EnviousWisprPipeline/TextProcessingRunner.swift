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

  private let logger: any PipelineLogging
  private let timeoutExecutor: TimeoutExecutor
  private let captureError: CaptureError

  init(
    logger: any PipelineLogging = AppLoggerAdapter(),
    captureError: @escaping CaptureError = {
      error, category, stage, extra, tags, fingerprintDetail in
      SentryBreadcrumb.captureError(
        error, category: category, stage: stage, extra: extra, tags: tags,
        fingerprintDetail: fingerprintDetail)
    },
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
    self.captureError = captureError
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
        if step.errorSurfacePolicy == .surface && !isSilentPolishSkip
          && contextWindowSkip == nil && !isAppleIntelligencePolishTimeout
          && !isEGOnePolishTimeout
          && !isCancellationLike
        {
          if let provider = polishProviderAtStart, provider != .appleIntelligence {
            // Cloud (OpenAI/Gemini) or local (Ollama): classify the specific
            // reason once, then feed it into BOTH the self-contained on-screen
            // notice and the telemetry reason tag (#945). The capture is
            // fire-and-forget; the raw transcript/prompt/provider-body never
            // leave the device (the reason set is closed and content-free).
            let reason = PolishFailureReason.from(error)
            polishError = reason.composedMessage(provider: provider)
            captureError(
              error,
              .polishProviderFailed,
              "polish",
              [
                "provider": provider.rawValue,
                "model": polishModelAtStart ?? "unknown",
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
          } else if polishProviderAtStart == .appleIntelligence {
            // Apple Intelligence: preserve today's exact wording byte-for-byte.
            // The view now renders `polishError` verbatim, so the runner owns the
            // "AI polish failed:" prefix here. AFM generation failures are
            // captured at the polish step, so no capture fires here.
            polishError = "AI polish failed: " + error.localizedDescription
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
          TelemetryService.shared.polishSkipped(
            provider: LLMProvider.appleIntelligence.rawValue, reason: skipReason)
        } else if isAppleIntelligencePolishTimeout {
          TelemetryService.shared.polishSkipped(
            provider: LLMProvider.appleIntelligence.rawValue, reason: "context_window_timeout")
        } else if isEGOnePolishTimeout {
          // #1271: one `local_polish_` prefix family for every EG-1 skip mode.
          TelemetryService.shared.polishSkipped(
            provider: LLMProvider.egOne.rawValue, reason: "local_polish_timeout")
        } else if let egOneSkipReason {
          TelemetryService.shared.polishSkipped(
            provider: LLMProvider.egOne.rawValue, reason: egOneSkipReason)
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
