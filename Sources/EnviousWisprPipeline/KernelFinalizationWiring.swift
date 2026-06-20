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
  /// #1050 honest disaggregation of `pipelineFellBackToRaw`; AFM-gated downstream.
  var polishFallbackReason: String?
  var pipelineStartedAtSeconds: Double?
  var pipelineEndedAtSeconds: Double?
  var asrStartedAtSeconds: Double?
  var asrEndedAtSeconds: Double?
  var streamingMode = false
  var polishDurationSeconds: Double = 0
  var pasteDurationSeconds: Double = 0
  var pasteResult: PasteDeliveryResult?
  /// #145: deterministic ITN run facts, threaded onto `dictation.completed`.
  /// Metadata only (`telemetry-privacy-boundary`). `itnFloorDelivered` is derived
  /// in `updateTranscriptMetrics` from `itnChanged` + the polish outcome.
  var itnRan = false
  var itnChanged = false
  var itnSkipReason: String?
  var itnLatencyMs: Double?
  var itnLenBefore: Int?
  var itnLenAfter: Int?
  /// #761: deterministic emoji-restore facts, threaded onto `dictation.completed`.
  /// Counts only (`telemetry-privacy-boundary`). Populated only on an AFM run; the
  /// optionals stay nil for cloud / Ollama / no-polish dictations.
  var emojiRan = false
  var emojiInInput: Int?
  var emojiDropped: Int?
  var emojiRestored: Int?
  var emojiRestoreIncomplete: Bool?
  var emojiLatencyMs: Double?

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
    adapter: any ASREngineAdapter,
    steps: LimbSteps,
    textProcessingRunner: TextProcessingRunner,
    save: @escaping @MainActor (Transcript) throws -> Void,
    deliverPaste: @escaping @MainActor (PasteDeliveryRequest) async -> PasteDeliveryResult,
    pasteCompletionRegistry: PasteCompletionRegistry?,
    // #900 clock seam — defaults to today's live expression, so production
    // behavior is identical (the closure capture adds one call). A test injects
    // a manual clock to advance logical time by hand and assert the tick rate,
    // instead of sleeping (which `tests-no-real-time-scheduling-precision` bans).
    // Trailing-defaulted so the other construction sites stay source-compatible.
    currentTime: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    // #950 — the SAME shared `KernelTelemetryState` the kernel stamps and the
    // lifecycle sink reads; the metrics builder reads the kernel-computed
    // tail-trim diagnostic from it for the PostHog `asr.completed` event.
    // Defaulted (fresh, tail fields nil) so other construction sites stay
    // source-compatible; the factory passes the shared instance.
    telemetryState: KernelTelemetryState = KernelTelemetryState()
  ) {
    // processText — run the limb chain, write the polish side-channel, return
    // the final display text. `onPolishStarted` is wired into
    // `LLMPolishStep.onWillProcess` so the limb emits and the kernel observes
    // (D18 closed for Parakeet — PR-4 §3.8).
    processText = { raw, onPolishStarted in
      steps.llmPolish.onWillProcess = { onPolishStarted() }
      // PR-5 Rung 5 (#827): wire engine LID -> polish for engines that detect.
      // Parakeet (no LID) returns nil through the cast; polish-step stays nil
      // and planner uses legacy prompt path. WhisperKit returns the last LID
      // result; planner reads it via `LLMPolishStep.languageDetection`.
      steps.llmPolish.languageDetection =
        (adapter as? any ASREngineLanguageIdentifying)?.lastLanguageDetection
      // #145: per-session capability hint for the ITN gate. Use the CAPABILITY,
      // never an engine-identity literal (`EngineIdentityFreezeTests` bans
      // identity reads outside the factory). Mirrors the `languageDetection`
      // wire above.
      steps.inverseTextNormalization.backendSupportsLID =
        adapter.capabilities.supportsLanguageDetection
      let language: String? = {
        if case .locked(let code) = context.config?.languageMode { return code }
        return nil
      }()
      let start = CFAbsoluteTimeGetCurrent()
      // #145: ITN runs BEFORE polish so it doubles as the raw-fallback floor —
      // polish-rejected/disabled both deliver the post-ITN text.
      let result = try await textProcessingRunner.run(
        rawText: raw,
        language: language,
        targetAppName: context.targetApp?.localizedName,
        steps: [
          steps.wordCorrection, steps.fillerRemoval, steps.emojiFormatter,
          steps.inverseTextNormalization, steps.llmPolish, steps.emojiRestore,
        ])
      let ctx = result.context
      // #145: thread the ITN run outcome onto `dictation.completed` (metadata
      // only — `telemetry-privacy-boundary`). Read on the same actor right after
      // the chain; `itn_floor_delivered` is computed later in
      // `updateTranscriptMetrics` where the polish outcome is known.
      if let itn = steps.inverseTextNormalization.lastRun {
        outcome.itnRan = itn.ran
        outcome.itnChanged = itn.changed
        outcome.itnSkipReason = itn.skipReason
        outcome.itnLatencyMs = itn.latencyMs
        outcome.itnLenBefore = itn.lenBefore
        outcome.itnLenAfter = itn.lenAfter
      }
      // #761: thread the emoji-restore outcome onto `dictation.completed`
      // (counts only — `telemetry-privacy-boundary`). The always-on step stamps
      // `lastRun` only on an AFM run and clears it to nil otherwise, so RESET on
      // the nil path — a prior AFM dictation's counts must never ride a later
      // (cloud / no-polish) transcript through the reused `outcome`.
      if let emoji = steps.emojiRestore.lastRun {
        outcome.emojiRan = emoji.ran
        outcome.emojiInInput = emoji.emojiInInput
        outcome.emojiDropped = emoji.dropped
        outcome.emojiRestored = emoji.restored
        outcome.emojiRestoreIncomplete = emoji.incomplete
        outcome.emojiLatencyMs = emoji.latencyMs
      } else {
        outcome.emojiRan = false
        outcome.emojiInInput = nil
        outcome.emojiDropped = nil
        outcome.emojiRestored = nil
        outcome.emojiRestoreIncomplete = nil
        outcome.emojiLatencyMs = nil
      }
      outcome.rawText = ctx.text
      outcome.polishedText = ctx.polishedText
      outcome.llmProvider = ctx.llmProvider
      outcome.llmModel = ctx.llmModel
      outcome.polishMetadata = ctx.polishMetadata
      outcome.pipelineFellBackToRaw = ctx.pipelineFellBackToRaw
      outcome.polishFallbackReason = ctx.polishFallbackReason
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
        backendType: adapter.engineIdentity.backendType,
        llmProvider: outcome.llmProvider,
        llmModel: outcome.llmModel,
        // #1063 PR1: link this live transcript to its crash-recovery spool (nil
        // unless recovery was armed) so the host deletes that session's spool +
        // key once this save is durable. `isRecovered` is false — this is the
        // live take, not a rescued one.
        recoverySessionID: context.config?.recoverySessionID,
        isRecovered: false)
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
      Self.updateTranscriptMetrics(
        outcome: outcome, context: context, telemetryState: telemetryState)
      Self.logPipelineTimingTotal(outcome: outcome)
      // PR-5 Rung 4.5 (#827): LID perf signpost `t_clipboard_write` —
      // gated on engine LID capability (NOT paste outcome). OLD pipeline
      // at `WhisperKitPipeline.swift:1079-1086` emits after finalize
      // regardless of cascade tier, including clipboard-only + auto-copy.
      // Source session id + LID-shape from `adapter.lastASRDiagnostics`
      // (per-session captured in adapter at `beginSession`).
      if adapter.capabilities.supportsLanguageDetection {
        Self.emitLIDClipboardWriteSignpost(
          diagnostics: (adapter as? any ASREngineTelemetryProviding)?.lastASRDiagnostics)
      }
      return deliveryOutcome
    }

    // Logical clock — production values for the kernel's wedge detection
    // (PR-4 §3.6). `currentTick` quantizes `systemUptime` to 100 ms ticks
    // (precedent: `LoadProgressWatcher.currentTime`).
    currentTick = {
      UInt64(currentTime() / Self.tickDurationSeconds)
    }
    sleepTicks = { ticks in
      try? await Task.sleep(for: .seconds(Double(ticks) * Self.tickDurationSeconds))
    }
  }

  /// #145: did the user actually GET the ITN floor? True when ITN changed the
  /// text AND polish did not deliver a DISTINCT polished result — disabled /
  /// unavailable / too-short bypass (no polished text — since #1022 the
  /// "too short" skip leaves `polishedText` nil), ran-and-rejected (fell back
  /// to raw), OR ran-but-identical (polished == the post-ITN text). NOTE
  /// (corrected #1050): the ran-but-identical case ALSO sets
  /// `pipelineFellBackToRaw` (the `validatedText == context.text` arm in
  /// `LLMPolishStep`, surfaced as reason `no_change`); the explicit
  /// `polishedText == rawText` clause is a redundant safety net for any path
  /// that delivers polished == raw without the flag. In all cases the
  /// pasted text is the post-ITN text. `rawText` is the final chain text
  /// (post-ITN), set in `processText`. Internal for a direct parametric test.
  static func itnFloorDelivered(
    itnChanged: Bool,
    polishedText: String?,
    rawText: String?,
    pipelineFellBackToRaw: Bool
  ) -> Bool {
    guard itnChanged else { return false }
    return polishedText == nil || pipelineFellBackToRaw || polishedText == rawText
  }

  private static func updateTranscriptMetrics(
    outcome: KernelFinalizationOutcome,
    context: KernelSessionContext,
    telemetryState: KernelTelemetryState
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

    let itnFloorDelivered = Self.itnFloorDelivered(
      itnChanged: outcome.itnChanged,
      polishedText: outcome.polishedText,
      rawText: outcome.rawText,
      pipelineFellBackToRaw: outcome.pipelineFellBackToRaw)

    transcript.metrics = ExecutionMetrics(
      asrLatencySeconds: asrLatency,
      llmLatencySeconds: outcome.polishDurationSeconds,
      pasteTier: outcome.pasteResult?.pasteTierLabel,
      pasteLatencyMs: outcome.pasteResult?.durationMs,
      targetApp: context.targetApp?.bundleIdentifier,
      coldStart: false,
      streamingMode: outcome.streamingMode,
      e2eSeconds: e2e,
      polishFilterTripped: outcome.polishMetadata?.filterTripped,
      polishFellBackToRaw: outcome.polishMetadata == nil ? nil : outcome.pipelineFellBackToRaw,
      polishFallbackReason: outcome.polishMetadata == nil ? nil : outcome.polishFallbackReason,
      itnRan: outcome.itnRan,
      itnChanged: outcome.itnChanged,
      itnFloorDelivered: itnFloorDelivered,
      itnSkipReason: outcome.itnSkipReason,
      itnLatencyMs: outcome.itnLatencyMs,
      itnLenBefore: outcome.itnLenBefore,
      itnLenAfter: outcome.itnLenAfter,
      // #950 tail-trim diagnostic — kernel-computed, read from the shared
      // telemetry state (eligible Parakeet batch only; nil for streaming /
      // WhisperKit / non-success). Carried onto `asr.completed`.
      tailDroppedMs: telemetryState.asrCompletedTelemetry?.droppedTailMs,
      tailHadEnergy: telemetryState.asrCompletedTelemetry?.tailHadEnergy,
      // #950 tail-preserve recovery + tuning signals.
      usedTailPreservation: telemetryState.asrCompletedTelemetry?.usedTailPreservation,
      recoveredTailMs: telemetryState.asrCompletedTelemetry?.recoveredTailMs,
      tailVoicedFraction: telemetryState.asrCompletedTelemetry?.tailVoicedFraction,
      tailRefusedReason: telemetryState.asrCompletedTelemetry?.tailRefusedReason,
      // #761 deterministic emoji-restore facts (counts only). Populated only on
      // an AFM run; nil for cloud / Ollama / no-polish and pre-#761 records.
      emojiInInput: outcome.emojiRan ? outcome.emojiInInput : nil,
      emojiDropped: outcome.emojiRan ? outcome.emojiDropped : nil,
      emojiRestored: outcome.emojiRan ? outcome.emojiRestored : nil,
      emojiRestoreIncomplete: outcome.emojiRan ? outcome.emojiRestoreIncomplete : nil,
      emojiLatencyMs: outcome.emojiRan ? outcome.emojiLatencyMs : nil
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

  /// PR-5 Rung 4.5 (#827): LID perf signpost `t_clipboard_write` — fires
  /// when finalization completes for WhisperKit-mode sessions, regardless
  /// of paste outcome. Source session id + LID shape from
  /// `adapter.lastASRDiagnostics` (per-session captured in the WK adapter
  /// at `beginSession`; race-safe vs delayed emit). Matches OLD
  /// `WhisperKitPipeline.swift:1079-1086` emit format.
  private static func emitLIDClipboardWriteSignpost(
    diagnostics: KernelASRAdapterDiagnostics?
  ) {
    let id = diagnostics?.lidCaptureSessionID ?? 0
    let ts = String(format: "%.6f", CFAbsoluteTimeGetCurrent())
    var fields = [
      "lid_perf_signpost",
      "name=t_clipboard_write",
      "timestamp_s=\(ts)",
      "session_id=\(id)",
    ]
    if let voiced = diagnostics?.lidVoicedDurationSec {
      fields.append("voiced_duration_s=\(String(format: "%.3f", voiced))")
    }
    if let lidWindow = diagnostics?.lidWindowCount {
      fields.append("lid_window_count=\(lidWindow)")
    }
    if let clipKind = diagnostics?.lidClipKind {
      fields.append("clip_kind=\(clipKind)")
    }
    let message = fields.joined(separator: " ")
    Task {
      await AppLogger.shared.log(message, level: .info, category: "KernelFinalizationWiring")
    }
  }
}
