import AppKit
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation

// MARK: - KernelFinalizationWiring (epic #827, PR-4 §3.3, §3.6)
//
// Assembles the kernel's post-ASR seams. `RecordingSessionKernel` takes its
// finalization as three narrow closures (`processText` / `store` / `deliver`)
// plus a logical clock (`currentTick` / `sleepTicks`). This helper builds them
// from the real text-processing / storage / paste types — the documented,
// single-unit-reviewable home for the run -> store -> deliver wiring, so the
// App's kernel construction site does not grow a 40-line closure literal.
//
// `TranscriptFinalizer.swift` is NOT edited: PR-4 wires the kernel's three
// closures to the three sub-types `TranscriptFinalizer` already composes
// (`TextProcessingRunner` / `TranscriptStore` / `PasteCascadeExecutor`).
// `TranscriptFinalizer` stays live for WhisperKit until PR-5/PR-9.
//
// PR-4a ships this production-unwired: no App-layer caller constructs it.

/// The polish/storage side-channel (PR-4 §3.3). The kernel's three closures
/// thread only a `String`; this reference carries the raw / polished split and
/// the polish metadata the `store` closure and the driver need. `@Observable`
/// so a driver reading `transcript` / `polishError` from it tracks changes.
@MainActor
@Observable
final class KernelFinalizationOutcome {
  /// The `Transcript` the `store` closure built and saved — the driver reads
  /// this as `currentTranscript`.
  var transcript: Transcript?
  /// The polish-step error, or `nil` — the driver reads this as `lastPolishError`.
  var polishError: String?
  /// Raw ASR text (pre-polish) — `store` uses it for `Transcript.text`.
  var rawText: String?
  /// Polished text, or `nil` — `store` uses it for `Transcript.polishedText`.
  var polishedText: String?
  /// Polish provider / model identity for `Transcript`.
  var llmProvider: String?
  var llmModel: String?
  /// Polish metadata + timing — carried for the PR-4b `ExecutionMetrics`
  /// assembly (§8 polish-latency capture).
  var polishMetadata: PolishMetadata?
  var pipelineFellBackToRaw = false
  var pipelineStartedAtSeconds: Double?
  var pipelineEndedAtSeconds: Double?
  var asrStartedAtSeconds: Double?
  var asrEndedAtSeconds: Double?
  var streamingMode = false
  var polishDurationSeconds: Double = 0
  var pasteDurationSeconds: Double = 0
  var pasteResult: PasteDeliveryResult?

  init() {}
}

/// Per-session inputs the finalization closures need but the kernel's narrow
/// closure signatures do not thread (PR-4 §3.3 — "captured by the driver and
/// threaded into the wiring"). A mutable holder shared by the driver (the
/// writer — PR-4b populates it in `handle(.toggleRecording)`) and the wiring
/// closures (the readers).
@MainActor
final class KernelSessionContext {
  /// The frozen per-recording config — VAD, decode language, paste prefs.
  var config: DictationSessionConfig?
  /// The frontmost app captured at recording start, re-activated before paste.
  var targetApp: NSRunningApplication?
  /// The focused text element captured at recording start.
  var targetElement: AXUIElement?

  init() {}
}

/// Builds the kernel's `processText` / `store` / `deliver` closures + logical
/// clock from the real finalization types.
@MainActor
struct KernelFinalizationWiring {

  // MARK: Wedge-detection tuning (PR-4 §3.6)

  /// Logical-tick granularity. Parakeet load-progress ticks arrive far slower
  /// than 100 ms apart, so a healthy load refreshes the wedge watcher well
  /// within every window.
  static let tickDurationSeconds: Double = 0.1

  /// Wedge window in ticks: `10 x 100 ms = 1.0 s`. Above `LoadProgressWatcher`'s
  /// 0.8 s silence floor (`LoadProgressWatcher.swift:41`) with a 200 ms margin —
  /// the kernel's cadence detector cannot false-positive a wedge sooner than
  /// today's shipped detector is even allowed to (no arbitrary timeout; both
  /// values are precedent-derived).
  static let wedgeStallTicks: Int = 10

  // MARK: Assembled seams

  let processText:
    @MainActor (_ raw: String, _ onPolishStarted: @escaping @MainActor () -> Void)
      async throws -> String
  let store: @MainActor (_ text: String) async throws -> Void
  let deliver: @MainActor (_ text: String) async -> KernelDeliveryOutcome
  let currentTick: @MainActor () -> UInt64
  let sleepTicks: @MainActor (Int) async -> Void

  /// `save` and `deliverPaste` are closure seams over `TranscriptStore.save`
  /// and `PasteCascadeExecutor.deliver` — the same test-seam shape
  /// `TranscriptFinalizer` exposes. The App wraps the concrete types; tests
  /// pass fakes without touching disk or the AX paste APIs.
  init(
    outcome: KernelFinalizationOutcome,
    context: KernelSessionContext,
    adapter: ParakeetEngineAdapter,
    steps: LimbSteps,
    textProcessingRunner: TextProcessingRunner,
    save: @escaping @MainActor (Transcript) throws -> Void,
    deliverPaste: @escaping @MainActor (PasteDeliveryRequest) async -> PasteDeliveryResult,
    pasteCompletionRegistry: PasteCompletionRegistry?
  ) {
    // processText — run the limb chain, write the polish side-channel, return
    // the final display text. `onPolishStarted` is wired into
    // `LLMPolishStep.onWillProcess` so the limb emits and the kernel observes
    // (D18 closed for Parakeet — PR-4 §3.8).
    processText = { raw, onPolishStarted in
      steps.llmPolish.onWillProcess = { onPolishStarted() }
      let language: String? = {
        if case .locked(let code) = context.config?.languageMode { return code }
        return nil
      }()
      let start = CFAbsoluteTimeGetCurrent()
      let result = try await textProcessingRunner.run(
        rawText: raw,
        language: language,
        targetAppName: context.targetApp?.localizedName,
        steps: [
          steps.wordCorrection, steps.fillerRemoval, steps.emojiFormatter, steps.llmPolish,
        ])
      let ctx = result.context
      outcome.rawText = ctx.text
      outcome.polishedText = ctx.polishedText
      outcome.llmProvider = ctx.llmProvider
      outcome.llmModel = ctx.llmModel
      outcome.polishMetadata = ctx.polishMetadata
      outcome.pipelineFellBackToRaw = ctx.pipelineFellBackToRaw
      outcome.polishError = result.polishError
      outcome.polishDurationSeconds = CFAbsoluteTimeGetCurrent() - start
      return ctx.polishedText ?? ctx.text
    }

    // store — build the Transcript exactly as TranscriptFinalizer.swift:129
    // (raw / polished from the side-channel, ASR metadata from the adapter),
    // persist it, and hand it to the driver via the side-channel. A throw
    // propagates so the kernel routes `failed(storageFailed)` (PR-4 §3.3).
    store = { text in
      let transcript = Transcript(
        text: outcome.rawText ?? text,
        polishedText: outcome.polishedText,
        language: adapter.lastResult?.language,
        duration: adapter.lastResult?.duration ?? 0,
        processingTime: adapter.lastResult?.processingTime ?? 0,
        backendType: .parakeet,
        llmProvider: outcome.llmProvider,
        llmModel: outcome.llmModel)
      try save(transcript)
      outcome.transcript = transcript
    }

    // deliver — run the paste cascade or clipboard copy per the session's
    // paste prefs, map `PasteDeliveryResult` -> `KernelDeliveryOutcome`, emit
    // the paste-completion event only on a real delivered paste
    // (TranscriptFinalizer.swift:163).
    deliver = { text in
      let pasteStart = CFAbsoluteTimeGetCurrent()
      let config = context.config
      var pasteResult: PasteDeliveryResult?
      let deliveryOutcome: KernelDeliveryOutcome
      if config?.autoPasteToActiveApp == true {
        let pasteText = PasteService.appendTrailingSpace(text)
        let result = await deliverPaste(
          PasteDeliveryRequest(
            text: pasteText,
            targetApp: context.targetApp,
            targetElement: context.targetElement,
            restoreClipboardAfterPaste: config?.restoreClipboardAfterPaste ?? false))
        pasteResult = result
        if case .delivered = result.outcome {
          pasteCompletionRegistry?.emit(
            PasteCompletionEvent(
              pastedText: pasteText,
              destinationBundleID: context.targetApp?.bundleIdentifier))
          deliveryOutcome = .pasted
        } else {
          deliveryOutcome = .clipboardOnly
        }
      } else if config?.autoCopyToClipboard == true {
        PasteService.copyToClipboard(text)
        deliveryOutcome = .clipboardOnly
      } else {
        deliveryOutcome = .clipboardOnly
      }

      let pipelineEnd = CFAbsoluteTimeGetCurrent()
      outcome.pipelineEndedAtSeconds = pipelineEnd
      outcome.pasteResult = pasteResult
      outcome.pasteDurationSeconds = pipelineEnd - pasteStart
      Self.updateTranscriptMetrics(outcome: outcome, context: context)
      Self.logPipelineTimingTotal(outcome: outcome)
      return deliveryOutcome
    }

    // Logical clock — production values for the kernel's wedge detection
    // (PR-4 §3.6). `currentTick` quantizes `systemUptime` to 100 ms ticks
    // (precedent: `LoadProgressWatcher.currentTime`).
    currentTick = {
      UInt64(ProcessInfo.processInfo.systemUptime / Self.tickDurationSeconds)
    }
    sleepTicks = { ticks in
      try? await Task.sleep(for: .seconds(Double(ticks) * Self.tickDurationSeconds))
    }
  }

  private static func updateTranscriptMetrics(
    outcome: KernelFinalizationOutcome,
    context: KernelSessionContext
  ) {
    guard var transcript = outcome.transcript else { return }
    let asrLatency =
      outcome.asrStartedAtSeconds.flatMap { start in
        outcome.asrEndedAtSeconds.map { $0 - start }
      }
    let e2e =
      outcome.pipelineStartedAtSeconds.flatMap { start in
        outcome.pipelineEndedAtSeconds.map { $0 - start }
      }

    transcript.metrics = ExecutionMetrics(
      asrLatencySeconds: asrLatency,
      llmLatencySeconds: outcome.polishDurationSeconds,
      pasteTier: outcome.pasteResult?.pasteTierLabel,
      pasteLatencyMs: outcome.pasteResult?.durationMs,
      targetApp: context.targetApp?.bundleIdentifier,
      coldStart: false,
      streamingMode: outcome.streamingMode,
      e2eSeconds: e2e,
      polishRouterMode: outcome.polishMetadata?.routerMode,
      polishRouterBasis: outcome.polishMetadata?.routerBasis,
      polishFilterTripped: outcome.polishMetadata?.filterTripped,
      polishFellBackToRaw: outcome.polishMetadata == nil ? nil : outcome.pipelineFellBackToRaw
    )
    outcome.transcript = transcript
  }

  private static func logPipelineTimingTotal(outcome: KernelFinalizationOutcome) {
    let e2e =
      outcome.pipelineStartedAtSeconds.flatMap { start in
        outcome.pipelineEndedAtSeconds.map { $0 - start }
      } ?? 0
    let asr =
      outcome.asrStartedAtSeconds.flatMap { start in
        outcome.asrEndedAtSeconds.map { $0 - start }
      } ?? 0

    Task {
      await AppLogger.shared.log(
        "Pipeline timing TOTAL: \(String(format: "%.3f", e2e))s "
          + "(ASR=\(String(format: "%.3f", asr))s, "
          + "polish=\(String(format: "%.3f", outcome.polishDurationSeconds))s, "
          + "paste=\(String(format: "%.3f", outcome.pasteDurationSeconds))s)",
        level: .info, category: "PipelineTiming"
      )
    }
  }
}
