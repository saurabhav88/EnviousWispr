import AppKit
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import EnviousWisprStorage
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
  var polishDurationSeconds: Double = 0

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

  init(
    outcome: KernelFinalizationOutcome,
    context: KernelSessionContext,
    adapter: ParakeetEngineAdapter,
    steps: LimbSteps,
    textProcessingRunner: TextProcessingRunner,
    transcriptStore: TranscriptStore,
    pasteExecutor: PasteCascadeExecutor,
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
      try transcriptStore.save(transcript)
      outcome.transcript = transcript
    }

    // deliver — run the paste cascade or clipboard copy per the session's
    // paste prefs, map `PasteDeliveryResult` -> `KernelDeliveryOutcome`, emit
    // the paste-completion event only on a real delivered paste
    // (TranscriptFinalizer.swift:163).
    deliver = { text in
      let config = context.config
      if config?.autoPasteToActiveApp == true {
        let pasteText = PasteService.appendTrailingSpace(text)
        let result = await pasteExecutor.deliver(
          PasteDeliveryRequest(
            text: pasteText,
            targetApp: context.targetApp,
            targetElement: context.targetElement,
            restoreClipboardAfterPaste: config?.restoreClipboardAfterPaste ?? false))
        if case .delivered = result.outcome {
          pasteCompletionRegistry?.emit(
            PasteCompletionEvent(
              pastedText: pasteText,
              destinationBundleID: context.targetApp?.bundleIdentifier))
          return .pasted
        }
        return .clipboardOnly
      }
      if config?.autoCopyToClipboard == true {
        PasteService.copyToClipboard(text)
      }
      return .clipboardOnly
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
}
