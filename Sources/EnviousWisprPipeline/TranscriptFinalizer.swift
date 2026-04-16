import AppKit
import EnviousWisprCore
import EnviousWisprServices
import EnviousWisprStorage
import Foundation

/// Input for post-ASR finalization.
@MainActor
internal struct FinalizationRequest {
  let asrText: String
  let language: String?
  let duration: TimeInterval
  let processingTime: TimeInterval
  let backendType: ASRBackendType
  let targetApp: NSRunningApplication?
  let targetElement: AXUIElement?
  let autoCopyToClipboard: Bool
  let autoPasteToActiveApp: Bool
  let restoreClipboardAfterPaste: Bool
  let steps: [any TextProcessingStep]
}

/// Output from post-ASR finalization.
@MainActor
internal struct FinalizationResult {
  let transcript: Transcript
  let pasteResult: PasteDeliveryResult?
  /// Error message from polish step failure, if any.
  let polishError: String?
  /// Time spent in text processing (for metrics).
  let polishDurationSeconds: Double
  /// Time spent in paste (for metrics).
  let pasteDurationSeconds: Double
}

/// Typed errors so pipelines can decide the right fallback per category.
/// GPT Desktop review: a single generic throw path blurs storage failures
/// with polish failures, creating misleading Sentry data and wrong fallbacks.
internal enum FinalizationError: Error {
  /// Text processing ran but produced empty output
  case emptyAfterProcessing
  /// Transcript storage failed (disk full, permissions, etc.)
  case storageFailed(underlying: Error)
}

/// Orchestrates the post-ASR delivery path: text processing -> store -> paste.
///
/// Does NOT own pipeline state transitions. Returns data; the pipeline decides
/// .polishing, .complete, .error based on the result.
/// Does NOT own step instances. Steps are passed in via the request.
/// Does NOT emit pipeline-specific telemetry (ASR mode, backend, etc.).
@MainActor
internal final class TranscriptFinalizer {
  private let transcriptStore: TranscriptStore
  private let textProcessingRunner: TextProcessingRunner
  private let pasteExecutor: PasteCascadeExecutor

  init(
    transcriptStore: TranscriptStore,
    textProcessingRunner: TextProcessingRunner = TextProcessingRunner(),
    pasteExecutor: PasteCascadeExecutor = PasteCascadeExecutor()
  ) {
    self.transcriptStore = transcriptStore
    self.textProcessingRunner = textProcessingRunner
    self.pasteExecutor = pasteExecutor
  }

  /// Finalize a transcription: process text, store transcript, paste to target.
  ///
  /// Throws `FinalizationError` for typed failures. Throws `CancellationError` if cancelled.
  /// Text processing step failures are handled internally (heart & limbs) and reported
  /// via `polishError` in the result, NOT as thrown errors.
  func finalize(_ request: FinalizationRequest) async throws -> FinalizationResult {
    // 1. Text processing (step failures handled internally by runner)
    let polishStart = CFAbsoluteTimeGetCurrent()
    let processingResult = try await textProcessingRunner.run(
      rawText: request.asrText,
      language: request.language,
      targetAppName: request.targetApp?.localizedName,
      steps: request.steps
    )
    let polishEnd = CFAbsoluteTimeGetCurrent()

    Task {
      await AppLogger.shared.log(
        "Pipeline timing: text processing completed in \(String(format: "%.3f", polishEnd - polishStart))s",
        level: .info, category: "PipelineTiming"
      )
    }

    let context = processingResult.context
    let finalText = context.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !finalText.isEmpty else {
      throw FinalizationError.emptyAfterProcessing
    }

    // 2. Create and store transcript
    let transcript = Transcript(
      text: context.text,
      polishedText: context.polishedText,
      language: request.language,
      duration: request.duration,
      processingTime: request.processingTime,
      backendType: request.backendType,
      llmProvider: context.llmProvider,
      llmModel: context.llmModel
    )
    do {
      try transcriptStore.save(transcript)
    } catch {
      throw FinalizationError.storageFailed(underlying: error)
    }

    // 3. Paste (never throws -- paste cascade always falls back to clipboard)
    let pasteStart = CFAbsoluteTimeGetCurrent()
    var pasteResult: PasteDeliveryResult?
    if request.autoPasteToActiveApp {
      let text = PasteService.appendTrailingSpace(transcript.displayText)
      pasteResult = await pasteExecutor.deliver(
        PasteDeliveryRequest(
          text: text,
          targetApp: request.targetApp,
          targetElement: request.targetElement,
          restoreClipboardAfterPaste: request.restoreClipboardAfterPaste
        ))
    } else if request.autoCopyToClipboard {
      PasteService.copyToClipboard(transcript.displayText)
    }
    let pasteEnd = CFAbsoluteTimeGetCurrent()

    return FinalizationResult(
      transcript: transcript,
      pasteResult: pasteResult,
      polishError: processingResult.polishError,
      polishDurationSeconds: polishEnd - polishStart,
      pasteDurationSeconds: pasteEnd - pasteStart
    )
  }
}
