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

  private let logger: any PipelineLogging
  private let timeoutExecutor: TimeoutExecutor

  init(
    logger: any PipelineLogging = AppLoggerAdapter(),
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
        let reason = isTimeout ? "timed out" : "failed: \(error.localizedDescription)"
        // Apple Intelligence language-gate skips (unsupported input
        // language, output-language drift) are expected no-ops, not
        // polish failures. Log and continue with raw text; do not
        // set `polishError`, which would surface as "AI polish
        // failed" in the UI.
        let isLanguageGateSkip: Bool
        if let llmError = error as? LLMError {
          switch llmError {
          case .unsupportedInputLanguage, .outputLanguageDrift:
            isLanguageGateSkip = true
          default:
            isLanguageGateSkip = false
          }
        } else {
          isLanguageGateSkip = false
        }
        if step.errorSurfacePolicy == .surface && !isLanguageGateSkip {
          polishError = error.localizedDescription
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
