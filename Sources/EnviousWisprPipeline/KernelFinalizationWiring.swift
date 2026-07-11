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
  /// #1167: whether the durable history save succeeded. `false` ⟺ the save
  /// threw but delivery still proceeded (best-effort save). Default `true` (the
  /// happy path); the `store` closure sets it explicitly on each save attempt,
  /// and the driver resets it per session. The recovery-cleanup gate, the pill,
  /// the in-memory append, the success marker, and the `dictation.completed`
  /// telemetry all read this — clipboard behavior does NOT (it always reverts
  /// per the user's setting; `pipeline-mechanics.md` RULE: clipboard-restore-is-sacred).
  var historySaved = true
  /// #1167: the storage error when `historySaved == false`, else `nil`. The
  /// driver maps it to a normalized class + privacy-safe user reason via
  /// `HistorySaveErrorClass`.
  var historySaveError: Error?

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
  /// default 0.8 s silence floor (`silenceFloorSeconds` init default) with a
  /// 200 ms margin —
  /// the kernel's cadence detector cannot false-positive a wedge sooner than
  /// today's shipped detector is even allowed to (no arbitrary timeout; both
  /// values are precedent-derived).
  static let wedgeStallTicks: Int = 10

  // MARK: Assembled seams

  let processText:
    @MainActor (_ raw: String, _ onPolishStarted: @escaping @MainActor () -> Void)
      async throws -> String
  let store: @MainActor (_ text: String, _ transcriptID: UUID) async throws -> Void
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

      // #1358: the display text after the limb chain. `ctx.polishedText ?? ctx.text`
      // can be empty two ways for a short dictation: polish returned "" (no
      // empty guard in `validatePolishOutput` below 10 input words) with an
      // intact post-ITN floor `ctx.text`, OR a deterministic step emptied
      // `ctx.text` itself (bare filler, or word-correction on malformed data).
      // Deliver the first non-empty deterministic floor and STAMP the side-
      // channels so store()/deliver()/metrics/recovery all read ONE identical
      // value; return "" only when nothing lexical remains — the kernel routes
      // that to the quiet `.noSpeech` terminal (mirrors the #979 downgrade).
      if !(ctx.polishedText ?? ctx.text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return ctx.polishedText ?? ctx.text  // unchanged happy path
      }
      let floor = Self.emptyOutputRecoveryFloor(deterministicText: ctx.text, rawASR: raw)
      if !floor.isEmpty {
        outcome.rawText = floor
        outcome.polishedText = nil  // the "" polish never persists; History == clipboard
        // Preserve the invariant `(polishFallbackReason != nil) == pipelineFellBackToRaw`
        // (`TextProcessingStep.swift`). `llmProvider`/`llmModel`/`polishMetadata`
        // are retained — honest facts that a polish was attempted.
        outcome.pipelineFellBackToRaw = true
        outcome.polishFallbackReason = "empty_output_floor"
      }
      return floor
    }

    // store — build the Transcript exactly as TranscriptFinalizer.swift:129
    // (raw / polished from the side-channel, ASR metadata from the adapter),
    // best-effort persist it, and hand it to the driver via the side-channel.
    //
    // #1167: the save is BEST-EFFORT. `outcome.transcript` is set BEFORE the
    // save so completion telemetry + paste metrics (which read it) populate even
    // when the save throws. A storage failure (full disk / permission / read-only)
    // is recorded on the outcome + telemetry side-channel and ABSORBED — it does
    // NOT propagate, so the kernel proceeds to deliver the already-polished text
    // and finishes `.completed`. The crash-recovery spool is retained (cleanup is
    // gated on `historySaved`), so History self-heals on next launch. Clipboard
    // behavior is unchanged (`pipeline-mechanics.md` RULE: clipboard-restore-is-sacred).
    store = { text, transcriptID in
      let transcript = Transcript(
        id: transcriptID,
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
        isRecovered: false,
        // #1408: the mic died mid-recording and this is the salvaged take. Read
        // from the SAME shared `KernelTelemetryState` this closure already
        // captures for `historySaveFailed` — the kernel stamped the cause before
        // the exit, and nothing clears it until the next `start(config:)`. No
        // widened `store` signature; the holder is the single home.
        //
        // `isDeviceLoss`, NOT `!= nil`. An engine that failed to recover and a
        // broad capture-session failure are salvaged too, and badging those
        // transcripts with a permanent crossed-out microphone would tell the user
        // something that did not happen. This badge is durable and unfixable
        // after the fact, so it takes the strictest predicate.
        inputDeviceWasRemoved: telemetryState.interruptionCause?.isDeviceLoss == true)
      outcome.transcript = transcript
      do {
        try save(transcript)
        outcome.historySaved = true
        outcome.historySaveError = nil
      } catch {
        outcome.historySaved = false
        outcome.historySaveError = error
        // Mirror the failure onto the telemetry side-channel so the lifecycle
        // sink can withhold the "transcript durably saved" success marker on a
        // degraded-save completion (#1167).
        telemetryState.historySaveFailed = true
      }
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

  /// #1358: given an EMPTY limb-chain display result, the deterministic recovery
  /// floor to deliver. First non-empty of: the post-ITN `deterministicText`
  /// (polish returned empty but the word-corrected/ITN'd text is intact — the
  /// #145 floor), else the raw ASR when it still holds lexical content after
  /// filler-stripping (a step erased a real word), else "" — which the kernel
  /// routes to the quiet `.noSpeech` terminal.
  ///
  /// The raw-ASR rank ALWAYS strips fillers (via `TextLexicalContent`) regardless
  /// of the `fillerRemovalEnabled` toggle: pasting a bare filler as a recovery
  /// floor is never desired (founder directive 2026-07-11). Pure + `@MainActor`
  /// (the filler classifier reads the shared regex). Tested parametrically.
  @MainActor
  static func emptyOutputRecoveryFloor(deterministicText: String, rawASR: String) -> String {
    let deterministicFloor = deterministicText.trimmingCharacters(in: .whitespacesAndNewlines)
    if !deterministicFloor.isEmpty { return deterministicFloor }
    if TextLexicalContent.hasLexicalContentAfterRemovingFillers(rawASR) {
      return rawASR.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return ""
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

    // The fallback fields were historically AFM-only (`polishMetadata != nil`);
    // cloud/no-polish fallback reasons stay suppressed. #1358 adds a provider-
    // agnostic producer — the empty-output recovery floor stamps
    // `empty_output_floor` with no `polishMetadata` — so let THAT reason through
    // the AFM gate (and only that reason) so the recovery is observable in
    // telemetry without changing behavior for existing reasons. The pair is
    // gated together, so the `(reason != nil) == fellBackToRaw` invariant holds.
    let emitFallbackFields =
      outcome.polishMetadata != nil || outcome.polishFallbackReason == "empty_output_floor"

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
      polishFellBackToRaw: emitFallbackFields ? outcome.pipelineFellBackToRaw : nil,
      polishFallbackReason: emitFallbackFields ? outcome.polishFallbackReason : nil,
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
      // #1232 tail-clip telemetry — kernel-computed classifier + lead signals,
      // read from the shared telemetry state. Carried onto `asr.completed`.
      tailClipClassification: telemetryState.asrCompletedTelemetry?.tailClipClassification,
      captureTrailingSilenceMs: telemetryState.asrCompletedTelemetry?.captureTrailingSilenceMs,
      captureTail200Rms: telemetryState.asrCompletedTelemetry?.captureTail200Rms,
      captureTail200Peak: telemetryState.asrCompletedTelemetry?.captureTail200Peak,
      asrInputDurationMs: telemetryState.asrCompletedTelemetry?.asrInputDurationMs,
      asrLastTokenEndMs: telemetryState.asrCompletedTelemetry?.asrLastTokenEndMs,
      asrLastTokenGapMs: telemetryState.asrCompletedTelemetry?.asrLastTokenGapMs,
      asrChunked: telemetryState.asrCompletedTelemetry?.asrChunked,
      // #761 deterministic emoji-restore facts (counts only). Populated only on
      // an AFM run; nil for cloud / Ollama / no-polish and pre-#761 records.
      emojiInInput: outcome.emojiRan ? outcome.emojiInInput : nil,
      emojiDropped: outcome.emojiRan ? outcome.emojiDropped : nil,
      emojiRestored: outcome.emojiRan ? outcome.emojiRestored : nil,
      emojiRestoreIncomplete: outcome.emojiRan ? outcome.emojiRestoreIncomplete : nil,
      emojiLatencyMs: outcome.emojiRan ? outcome.emojiLatencyMs : nil,
      // #1309 effective-path streaming telemetry — kernel-assembled from the
      // adapter's diagnostics (WhisperKit only; nil omitted). `streamingMode`
      // above stays the REQUESTED mode.
      streamingEffective: telemetryState.asrCompletedTelemetry?.streamingEffective,
      streamingDegradeReason: telemetryState.asrCompletedTelemetry?.streamingDegradeReason,
      streamingFinalPath: telemetryState.asrCompletedTelemetry?.streamingFinalPath,
      streamingDecodeCount: telemetryState.asrCompletedTelemetry?.streamingDecodeCount,
      streamingCoveredSec: telemetryState.asrCompletedTelemetry?.streamingCoveredSec,
      tailDecodeSec: telemetryState.asrCompletedTelemetry?.tailDecodeSec,
      maxUnconfirmedWindowSec: telemetryState.asrCompletedTelemetry?.maxUnconfirmedWindowSec,
      stopWhileDecodeInFlight: telemetryState.asrCompletedTelemetry?.stopWhileDecodeInFlight
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
