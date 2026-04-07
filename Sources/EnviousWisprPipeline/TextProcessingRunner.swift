import EnviousWisprCore
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
/// ownership for PipelineSettingsSync mutation and polishExistingTranscript() access.
/// The runner owns only the execution algorithm: ordering, timeout, cancellation,
/// failure continuation (heart & limbs), and CORRECTION_DEBUG logging.
@MainActor
internal final class TextProcessingRunner {

    func run(
        rawText: String,
        language: String?,
        targetAppName: String?,
        steps: [any TextProcessingStep]
    ) async throws -> TextProcessingRunResult {
        var context = TextProcessingContext(text: rawText, language: language)
        context.targetAppName = targetAppName
        var polishError: String?

        Task {
            await AppLogger.shared.log(
                "CORRECTION_DEBUG [RAW ASR] \(rawText)",
                level: .info, category: "CorrectionDebug"
            )
        }

        for step in steps where step.isEnabled {
            let stepName = step.name
            let input = context
            // nonisolated(unsafe) is safe: the task group inherits @MainActor isolation,
            // so step.process() still runs on MainActor — no real isolation crossing.
            nonisolated(unsafe) let unsafeStep = step
            let stepStart = CFAbsoluteTimeGetCurrent()
            let budgetSeconds = Double(unsafeStep.maxDuration.components.seconds)
                              + Double(unsafeStep.maxDuration.components.attoseconds) / 1e18
            do {
                context = try await withThrowingTimeout(seconds: budgetSeconds) {
                    try await unsafeStep.process(input)
                }
                let stepMs = (CFAbsoluteTimeGetCurrent() - stepStart) * 1000
                let inputText = input.polishedText ?? input.text
                let outputText = context.polishedText ?? context.text
                let changed = inputText != outputText
                Task {
                    await AppLogger.shared.log(
                        "\(stepName) completed in \(String(format: "%.1f", stepMs))ms (budget: \(String(format: "%.0f", budgetSeconds * 1000))ms)",
                        level: .info, category: "PipelineTiming"
                    )
                    if changed {
                        await AppLogger.shared.log(
                            "CORRECTION_DEBUG [\(stepName)] IN:  \(inputText)",
                            level: .info, category: "CorrectionDebug"
                        )
                        await AppLogger.shared.log(
                            "CORRECTION_DEBUG [\(stepName)] OUT: \(outputText)",
                            level: .info, category: "CorrectionDebug"
                        )
                    } else {
                        await AppLogger.shared.log(
                            "CORRECTION_DEBUG [\(stepName)] no change",
                            level: .info, category: "CorrectionDebug"
                        )
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let stepMs = (CFAbsoluteTimeGetCurrent() - stepStart) * 1000
                let reason = error is TimeoutError ? "timed out" : "failed: \(error.localizedDescription)"
                if stepName == "LLM Polish" {
                    polishError = error.localizedDescription
                }
                Task {
                    await AppLogger.shared.log(
                        "\(stepName) \(reason) after \(String(format: "%.1f", stepMs))ms — skipping",
                        level: .info, category: "TextProcessing"
                    )
                }
                // Heart & Limbs: limb failed, continue with input text
            }
        }
        return TextProcessingRunResult(context: context, polishError: polishError)
    }
}
