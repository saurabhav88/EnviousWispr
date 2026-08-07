import AppKit
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprPostProcessing
import EnviousWisprServices
import Foundation
import os

// MARK: - KernelFinalizationWiring (epic #827, PR-4 §3.3, §3.6)
//
// Assembles the kernel's post-ASR seams. `RecordingSessionKernel` takes its
// finalization as three narrow closures (`processText` / `store` / `deliver`)
// plus a logical clock (`currentTick` / `sleepTicks`). This helper builds them
// from the real text-processing / storage / paste types — the documented,
// single-unit-reviewable home for the run -> store -> deliver wiring, so the
// App's kernel construction site does not grow a 40-line closure literal.
//
// This is the sole production finalization path. Its contracts run directly
// against these closures (`TextProcessingRunner` / `TranscriptStore` /
// `PasteCascadeExecutor`) in `KernelFinalizationWiringTests`.

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
  /// #1914: carried straight through from the context, never re-derived here.
  /// Nil unless an Ollama polish completed. See `TextProcessingContext`.
  var polishRanRemote: Bool?
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
  /// #1785 cursor-aware insertion. Four facts, and only four, because a
  /// wrong-case report arrives with no text attached and these are what make it
  /// answerable: was the feature even on, could the field be read, what did the
  /// repair decide, and what did the writing route actually submit.
  ///
  /// Shapes and closed-set names only, never a word of the user's document —
  /// the rule names carry the WHY (`notOrdinaryWord`, `protectedWord`,
  /// `languageNotSupported`) without carrying the word it applied to.
  var smartInsertionEnabled: Bool?
  var caretContextOutcome: String?
  var repairRules: String?
  /// #1921. `repairRules` says WHAT the repair decided; these say why the
  /// language question got the answer it did. Without them a fielded regression
  /// in the confidence gate is invisible: `case_skipped:language_not_supported`
  /// looks identical whether the user locked a language, the engine reported
  /// one, the recogniser was unsure, or the document vetoed.
  ///
  /// Closed-set category names only, never a language code, so this says how the
  /// gate behaved without shipping what language each user speaks.
  var languageResolutionSource: String?
  var languageConfidenceBucket: String?
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
  /// Canonical protected spellings, snapshotted at `processText` entry.
  ///
  /// `WordCorrectionStep.correctorVocabulary` is MUTABLE and
  /// `CustomWordsPropagator` can replace it mid-session, so reading it at
  /// delivery time would let a custom-word broadcast change a decision for a
  /// dictation already in flight. Captured once per session, before the first
  /// suspension point, and retained for that session's delivery.
  ///
  /// Canonicals only. Aliases are recognition triggers — the misheard forms we
  /// correct FROM — never protected output spellings.
  var protectedSpellings: Set<String> = []

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
  /// this wiring exposes. The App wraps the concrete types; tests
  /// pass fakes without touching disk or the AX paste APIs.
  init(
    outcome: KernelFinalizationOutcome,
    context: KernelSessionContext,
    adapter: any ASREngineAdapter,
    steps: LimbSteps,
    textProcessingRunner: TextProcessingRunner,
    save: @escaping @MainActor (Transcript) throws -> Void,
    deliverPaste: @escaping @MainActor (PasteDeliveryRequest) async -> PasteDeliveryResult,
    // Caret reader seam. Production reads the live focused field; tests inject
    // deterministic context so the real composition path can be driven without
    // depending on whatever field happens to be focused on the machine.
    // Caret reader seam. Production reads the live focused field, and supplies
    // the per-delivery terminal budget so a terminal read is bounded by the same
    // cumulative allowance as its later revalidation.
    readCaretContext: @escaping @MainActor (
      AXUIElement, TerminalResolutionBudget, ((TerminalContextRefusal) -> Void)?
    ) -> PasteService.CaretContext? = {
      PasteService.readCaretContext(element: $0, terminalBudget: $1, onTerminalRefusal: $2)
    },
    // Word-oracle seam. Production takes the live runtime snapshot; tests inject
    // a fixed oracle so a case never depends on the machine's dictionaries — and
    // so no test has to MUTATE the process-global runtime, which would race the
    // suites that legitimately do (local diff review, P2).
    // Takes the RESOLVED language, so it must be called after resolution, not
    // before it (grounded review r1: the snapshot used to be taken above the
    // deadline, where the language is not yet known).
    seamCasingOracle: @escaping @MainActor (String?) -> SeamCasingOracle = {
      SeamCasingOracleRuntime.snapshot(for: $0)
    },
    // Paired with the seam above. A READY snapshot holds a lease that stops the
    // preparation drain entering the shared spell checker underneath a decision
    // already in flight; releasing is mandatory and happens in a `defer`.
    // Injected tests pass a no-op, because their oracle takes no lease.
    releaseOracleLease: @escaping @MainActor () -> Void = {
      SeamCasingOracleRuntime.releaseDecisionLease()
    },
    // #1921 language-resolver seam. `@Sendable`, not `@MainActor`, because
    // resolution now runs INSIDE the `@Sendable` deadline operation. Defaults to
    // the real resolver, so production behaviour is identical.
    //
    // A test injects a blocking resolver to drive the REAL deadline into its two
    // reachable timeout orders. Without this the only way to reach them would be
    // to time work against the 100 ms boundary, which is a clock race.
    resolveLanguage: @escaping @Sendable (
      _ lockedLanguage: String?,
      _ engineDetectsLanguage: Bool,
      _ engineReportedLanguage: String?,
      _ text: String,
      _ surroundingText: String
    ) -> DictationLanguageResolver.Resolution = {
      DictationLanguageResolver.resolve(
        lockedLanguage: $0, engineDetectsLanguage: $1, engineReportedLanguage: $2,
        text: $3, surroundingText: $4)
    },
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
      // FIRST statement, before any suspension point: snapshot the canonical
      // protected spellings for this session. `correctorVocabulary` is mutable
      // and `CustomWordsPropagator` can replace it while this dictation is still
      // being processed; reading it at delivery time would let that broadcast
      // change a decision for text already in flight. Canonicals only — an alias
      // is a misheard form we correct FROM, never a spelling to protect.
      context.protectedSpellings = Set(
        steps.wordCorrection.correctorVocabulary.terms.map(\.canonical))
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
        ],
        // #1846: the LIVE in-flight take, not the concluded one. Polish runs before
        // the session terminal, and starting a session CLEARS `kernel.lastTakeID`,
        // so it is nil here — substituting it would emit no take key at all. Same
        // key as the completion events, read at a different point; swapping the two
        // reads would silently blank one family.
        takeID: telemetryState.takeID)
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
      // `lastRun` only on a RESTORING provider (Apple Intelligence, plus Ollama
      // since #1948) and clears it to nil otherwise, so RESET on the nil path —
      // a prior restoring dictation's counts must never ride a later (cloud /
      // no-polish) transcript through the reused `outcome`.
      //
      // #1948 telemetry note: `emoji_ran` and its sibling counts begin appearing
      // for Ollama takes on the release boundary. That is the guard starting to
      // work, not a regression; a dashboard reading "emoji_ran ⇒ Apple
      // Intelligence" silently widens and must be re-scoped by provider.
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
      outcome.polishRanRemote = ctx.polishRanRemote
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
        // #1914: finalization rejected the generated output, so this polish is
        // skipped. `llm.polish_completed` derives `result` from
        // `polishedText != nil`; leaving remoteness set would emit
        // `result: "skipped"` together with `ollama_remote`.
        outcome.polishRanRemote = nil
        // Preserve the invariant `(polishFallbackReason != nil) == pipelineFellBackToRaw`
        // (`TextProcessingStep.swift`). `llmProvider`/`llmModel`/`polishMetadata`
        // are retained — honest facts that a polish was attempted.
        outcome.pipelineFellBackToRaw = true
        outcome.polishFallbackReason = "empty_output_floor"
      }
      return floor
    }

    // store — build the Transcript from the polish side-channel
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
        // `isDeviceLoss`, NOT `!= nil`. An engine that failed to recover with
        // the device still attached is salvaged too, and badging that transcript
        // with a permanent crossed-out microphone would tell the user something
        // that did not happen. This badge is durable and unfixable after the
        // fact, so it takes the strictest predicate.
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
    // on a real delivered paste.
    deliver = { text in
      let pasteStart = CFAbsoluteTimeGetCurrent()
      let config = context.config
      var pasteResult: PasteDeliveryResult?
      let deliveryOutcome: KernelDeliveryOutcome
      // #1921: cleared BEFORE the auto-paste branch below, because `outcome` is
      // shared and reused across sessions. Everything that describes the
      // insertion repair is written inside that branch, so a clipboard-only
      // delivery would otherwise report the PREVIOUS dictation's language
      // decision as if it were this one's — a stale reading that looks exactly
      // like a real one in the field.
      //
      // Cleared to NIL, not to `"none"`. My first version wrote `"none"` here
      // and that broke the contract these fields exist to express: `"none"`
      // means the app measured and found no answer, nil means no measurement was
      // ever attempted. A clipboard-only session never reaches the resolver at
      // all, so `"none"` would have reported a measurement that did not happen
      // (integration review).
      outcome.languageResolutionSource = nil
      outcome.languageConfidenceBucket = nil
      if config?.autoPasteToActiveApp == true {
        // ONE cumulative terminal-resolution budget for this whole delivery,
        // created here and reused by every commit-boundary revalidation. A fresh
        // budget per route would let the total the user waits for grow with the
        // number of routes tried, which is the bound it exists to keep.
        let terminalBudget = TerminalResolutionBudget()

        // Read the caret ONCE, only when the frozen setting allows it and we
        // actually have a target. `readCaretContext` fails open, so a nil result
        // simply means no candidate.
        // The specific terminal refusal, so a wrong-case report can be diagnosed
        // from the log instead of guessed at. Names and shapes only.
        var terminalRefusal: TerminalContextRefusal?
        let caretContext: PasteService.CaretContext? = {
          guard config?.smartInsertion == true, let element = context.targetElement else {
            return nil
          }
          return readCaretContext(element, terminalBudget, { terminalRefusal = $0 })
        }()

        // ONE call to the repair, which is the sole owner of the trailing-space
        // rule. Even with no context it returns today's payload, so Pipeline
        // never recreates that rule and the two can never drift apart.
        // The oracle reaches a separate spelling-service process, so this is the
        // one place on the paste path with an unbounded cross-process call. AX
        // reads here are already capped by `AXUIElementSetMessagingTimeout`
        // (0.5s); `NSSpellChecker` has no equivalent knob, so the call is bounded
        // here instead — stricter than the 0.5s we already accept.
        //
        // `withOrderedDeadline`, not bare `withDeadline`: on timeout the runtime
        // must be latched BEFORE paste resumes, so a later dictation can never
        // race an abandoned call against AppKit's one shared spell checker.
        let repairContext: CursorInsertionRepair.CaretText? = caretContext.map {
          CursorInsertionRepair.CaretText(
            left: $0.leftWindow, right: $0.rightWindow,
            // Read, not derived. This was `leftWindow.utf16.count ==
            // selectionLocation`, which is exact for a real caret and vacuous
            // for a terminal — both values come from the same string there, so
            // EVERY screen-derived context claimed to reach the start, wrapped
            // ones included. Each source now states the fact it alone knows.
            leftReachesDocumentStart: $0.leftReachesDocumentStart,
            // The narrow policy fact the repair needs. A screen-derived line is
            // ONE rendered row, so a payload carrying a line break is refused
            // rather than reasoned about — in a terminal a newline can submit
            // the command.
            isScreenDerived: $0.isScreenDerived)
        }

        // Resolved from positive evidence, NOT read off the result.
        //
        // The earlier version of this line took `adapter.lastResult?.language`
        // and justified it as "Parakeet reports English, which is the only
        // language it transcribes". That was wrong, and our own settings
        // screen says so: Parakeet transcribes 25 European languages while
        // `ParakeetBackend` stamps `"en"` on every result. Since Parakeet is
        // the DEFAULT engine, a German dictation on the default path was being
        // recased with English rules — the exact defect the language gate was
        // built to prevent (cloud review, PR #1802).
        // Every `@MainActor` input, snapshotted BEFORE the `@Sendable` deadline
        // operation, which cannot reach a `@MainActor` seam.
        let lockedLanguageCode: String? = {
          if case .locked(let code) = context.config?.languageMode { return code }
          return nil
        }()
        let engineDetectsLanguage = adapter.capabilities.supportsLanguageDetection
        let engineReportedLanguage = adapter.lastResult?.language
        // The caret windows we already read. A short mid-sentence continuation
        // cannot always be identified on its own, and that is exactly the
        // insertion this feature exists for.
        let surroundingText = caretContext.map { $0.leftWindow + " " + $0.rightWindow } ?? ""
        let protectedSpellings = context.protectedSpellings

        // #1921: language resolution now runs INSIDE this deadline. It used to
        // run above it, unbounded, on the paste path — a claim an earlier
        // revision of the plan asserted was already true and was not.
        //
        // One gate arbitrates both stages, because "which stage timed out" now
        // decides whether `SeamCasingOracleRuntime` may be disabled, and a
        // plain flag cannot answer it safely: cancellation here is best-effort
        // and cannot preempt a running operation, so the timeout can look, see
        // the language stage, decline to disable, and the un-preempted operation
        // can then enter the oracle anyway.
        let gate = LanguageRepairDeadlineGate()
        // The timeout path's resolution. It cannot ride the operation's return
        // value, because on timeout the operation's value is discarded; and
        // `onTimeout` is `@Sendable`, so it cannot write to a captured `var`.
        let timedOutResolution = OSAllocatedUnfairLock<DictationLanguageResolver.Resolution?>(
          initialState: nil)

        let deadlineResult = await withOrderedDeadline(
          seconds: 0.100,
          operation: {
            let resolution = resolveLanguage(
              lockedLanguageCode, engineDetectsLanguage, engineReportedLanguage,
              text, surroundingText)
            guard gate.beginRepair(resolution) else {
              // The deadline already claimed the phase, so repair must not
              // start. This return value is discarded by the deadline's own
              // single-claim rule; it exists to leave the closure, not to be read.
              return (
                CursorInsertionRepair.legacyOnly(text: text, reason: .oracleTimedOut), resolution
              )
            }
            // The oracle asks the gate before every consultation, which both
            // tells the timeout a genuinely stuck oracle from repair stalling
            // before it ever got there, and refuses the call outright once the
            // deadline has fired. `repair` has early exits and does spacing work
            // first, so "repair started" is not "the oracle is running"
            // (integration review); and cancellation cannot preempt a blocked
            // thread, so without the refusal an un-preempted repair would still
            // enter the real oracle after the timeout gave up (integration
            // review round 2). Every refusal keeps the capital.
            // `CursorInsertionRepair` stays unaware of the deadline: it remains
            // a pure function of the oracle it is handed.
            // Taken HERE, below resolution, because the oracle is per-language
            // now and the language is not known any earlier. A ready snapshot
            // holds a lease; `defer` releases it on every exit including the
            // discarded-on-timeout one, since the deadline cannot preempt this
            // closure and it always runs to completion.
            let oracleSnapshot = await MainActor.run { seamCasingOracle(resolution.language) }
            // Release ONLY IF a lease was actually taken. `snapshot(for:)` leases
            // on a ready answer and not on a refusal, so an unconditional release
            // is not merely harmless bookkeeping: leases carry no identity, so an
            // unmatched release decrements whichever decision currently holds the
            // count, and the drain may then start preparing while that decision is
            // still inside the shared spell checker — precisely the race the lease
            // exists to close. Grounded review r3, MED.
            let holdsOracleLease = oracleSnapshot.isAvailable
            defer {
              if holdsOracleLease { Task { @MainActor in releaseOracleLease() } }
            }
            let gatedOracle = oracleSnapshot.authorized { gate.authorizeOracleUse() }
            let repaired = CursorInsertionRepair.repair(
              text: text,
              context: repairContext,
              protectedWords: protectedSpellings,
              language: resolution.language,
              oracle: gatedOracle)
            // Immediately after repair returns and before this closure does, so
            // the window in which a FINISHED oracle still looks stuck is as
            // small as the runtime allows.
            gate.completeRepair()
            return (repaired, resolution)
          },
          onTimeout: {
            let timeout = gate.timeOut()
            timedOutResolution.withLock { $0 = timeout.resolution }
            // Only a genuinely RUNNING oracle. A language-stage stall must not
            // disable an unrelated healthy component for the rest of the
            // process, and neither must one that had already succeeded.
            if timeout.shouldDisableOracle { SeamCasingOracleRuntime.disableAfterTimeout() }
          }
        )

        let payloads =
          deadlineResult?.0 ?? CursorInsertionRepair.legacyOnly(text: text, reason: .oracleTimedOut)
        let resolution = deadlineResult?.1 ?? timedOutResolution.withLock { $0 }

        // Why this dictation was or was not repaired, recorded before delivery
        // so it survives every route outcome. Names and shapes only (#1785 §8).
        outcome.smartInsertionEnabled = config?.smartInsertion
        outcome.caretContextOutcome = {
          if config?.smartInsertion != true { return "setting_off" }
          if context.targetElement == nil { return "no_target" }
          if let terminalRefusal { return terminalRefusal.rawValue }
          // #1932. A titled box is named separately so the field can see that
          // path working. The parser's own refusal names never get here —
          // `TerminalContextResolver` collapses all ten into
          // `terminal_screen_refused` on purpose, because that enum's raw values
          // are a shipped closed set — so a titled path that silently stopped
          // matching would be invisible without this. That is the six-week blind
          // spot #1926 sat in, and it is why declining this field on the
          // grounds that "the refusal side already shows it" was wrong.
          if caretContext?.terminalEvidence?.located.boxOpeningKind == .titled {
            return "terminal_read_titled_box"
          }
          if caretContext?.isScreenDerived == true { return "terminal_read" }
          return caretContext == nil ? "unreadable" : "read_selected"
        }()
        outcome.repairRules =
          payloads.candidateRules.isEmpty
          ? nil : payloads.candidateRules.map(\.telemetryName).joined(separator: ",")
        // #1921. An auto-paste attempt records the resolver outcome here,
        // overwriting the nil defaulted at the top of `deliver`. A
        // language-stage timeout records `none` because it genuinely produced
        // no answer before the deadline. Clipboard-only delivery never reaches
        // this block at all and so stays nil, because it never attempts
        // resolution — that is the whole distinction the two values carry.
        //
        // Two earlier versions of this comment were wrong, in opposite
        // directions. The first claimed the fields were "written on EVERY path";
        // they were not, because this block sits inside the auto-paste branch.
        // The second still said the default above was `none` after it had been
        // changed to nil. A comment asserting a property the code does not have
        // is worse than none, because it stops the next reader checking.
        outcome.languageResolutionSource = (resolution?.source ?? .none).rawValue
        outcome.languageConfidenceBucket = (resolution?.confidenceBucket ?? .none).rawValue

        // #1803: the repair decision has only ever gone to telemetry, so a
        // wrong-case report could not be diagnosed locally — which cost three
        // rounds of guessing during founder testing on 2026-07-26. Names and
        // shapes only, never a word of the document, so this respects the same
        // privacy boundary the telemetry does.
        // The per-step timings ride the SAME line, because the question they
        // answer is always "why did THIS outcome happen". Split across two
        // lines they would have to be correlated by timestamp, which is exactly
        // the reconstruction that made the 2026-08-04 breaker trip
        // undiagnosable. Empty when no bounded step ran, so a non-terminal app
        // does not gain a dangling ` timing=` on every dictation.
        let terminalTiming = terminalBudget.timingDescription
        await AppLogger.shared.log(
          "CURSOR_REPAIR app=\(context.targetApp?.bundleIdentifier ?? "nil") "
            + "caret=\(outcome.caretContextOutcome ?? "nil") "
            + "rules=\(outcome.repairRules ?? "none") "
            + "candidate=\(payloads.repairedText == nil ? "none" : "offered")"
            + (terminalTiming.isEmpty ? "" : " timing=[\(terminalTiming)]"),
          level: .info, category: "KernelFinalizationWiring")

        // The legacy payload is what a route falls back to; §6 decides per route
        // whether the candidate may be committed instead.
        let pasteText = payloads.legacyText
        let result = await deliverPaste(
          PasteDeliveryRequest(
            legacyText: pasteText,
            repairedText: payloads.repairedText,
            caretContext: caretContext,
            // Asked of the RULES, not enumerated here. Listing the destructive
            // ones at this call site is how the first version missed
            // `.droppedTerminalPeriod` — a rule that also removes a character
            // the user dictated, found by cloud review. `deletesDictatedText`
            // is an exhaustive switch beside the enum, so a new rule cannot
            // inherit "not destructive" by being forgotten out here.
            candidateDeletesDictatedText: payloads.candidateRules.contains {
              $0.deletesDictatedText
            },
            targetApp: context.targetApp,
            targetElement: context.targetElement,
            restoreClipboardAfterPaste: config?.restoreClipboardAfterPaste ?? false,
            terminalBudget: terminalBudget))
        pasteResult = result

        // WHICH payload actually went to the app, which `CURSOR_REPAIR` cannot
        // say because it is logged before the write happens.
        //
        // This is the gap that made the founder's original report
        // undiagnosable: the repair can decide `lowercased_first`, offer a
        // candidate, and the route can still commit the LEGACY text because
        // `payloadAtCommitBoundary` re-reads the caret and refuses when
        // anything changed. From the log alone those two outcomes were
        // indistinguishable — both showed `candidate=offered` and the user saw
        // the capital survive.
        //
        // A second line rather than a field on the first, only because the fact
        // does not exist until after the write. `tier` rides along so the two
        // can be matched without a timestamp join.
        // The FULL budget spend, which `CURSOR_REPAIR` structurally cannot show:
        // that line is written before the paste, and the commit-boundary
        // re-check runs after the target app is activated. On 2026-08-04 the
        // repair line reported a healthy 1.6 ms and the breaker tripped anyway,
        // because the whole overspend lived in the half no line covered.
        //
        // Everything before `|recheck|` was already on the repair line; the
        // suffix is new, and the total is what the cumulative cap is judged
        // against. That cap is `TerminalResolutionBudget.defaultTotal`, which
        // owns the current value — do not restate the number here, because a
        // second copy is what goes stale (it read "100 ms" until 2026-08-05).
        await AppLogger.shared.log(
          "CURSOR_COMMIT submitted=\(result.submittedPayload?.rawValue ?? "none") "
            + "tier=\(result.pasteTierLabel ?? "none") "
            + "timing=[\(terminalBudget.timingDescription)]",
          level: .info, category: "KernelFinalizationWiring")

        if case .delivered = result.outcome {
          // The text that actually LANDED, which is not always the one this
          // closure passed in: a route may have committed the contextual
          // candidate. `pasteCompletionRegistry`'s subscriber (#629) watches for
          // later edits to the pasted text and learns custom words from them, so
          // announcing the legacy payload after delivering the repaired one
          // would make our own spacing and casing look like the user correcting
          // us. Falls back to the legacy payload for `.legacy` and for a
          // delivered route that reported no payload at all.
          let deliveredText =
            result.submittedPayload == .repaired
            ? (payloads.repairedText ?? pasteText) : pasteText
          pasteCompletionRegistry?.emit(
            PasteCompletionEvent(
              pastedText: deliveredText,
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

    // The fallback fields were historically AFM-only (`polishMetadata != nil`).
    // #1358 added a provider-agnostic producer (the empty-output recovery
    // floor stamps `empty_output_floor` with no `polishMetadata`). Issue #158
    // widens this further: `outcome.llmProvider` is set on EVERY provider's
    // successful polish path (`LLMPolishStep.swift`, the AFM arm and the "all
    // other providers" arm both stamp it), so gating on its presence lets
    // every provider's `fell_back_to_raw`/`fallback_reason` through, not just
    // AFM's — a successful Claude/OpenAI/Gemini/Ollama/EG-1 call whose output
    // was later found unchanged or rejected by a post-generation guard now
    // reports honestly, matching what AFM has always reported. This is a
    // telemetry-only change: `pipelineFellBackToRaw` above (which drives
    // actual pipeline behavior) is unaffected.
    let emitFallbackFields =
      outcome.polishMetadata != nil || outcome.polishFallbackReason == "empty_output_floor"
      || outcome.llmProvider != nil

    transcript.metrics = ExecutionMetrics(
      asrLatencySeconds: asrLatency,
      llmLatencySeconds: outcome.polishDurationSeconds,
      pasteTier: outcome.pasteResult?.pasteTierLabel,
      pasteLatencyMs: outcome.pasteResult?.durationMs,
      // #1785: why this dictation was or was not repaired, and which payload the
      // writing route submitted. `pastePayloadKind` stays nil when no route
      // reached a write at all, which is distinct from submitting the legacy one.
      smartInsertionEnabled: outcome.smartInsertionEnabled,
      caretContextOutcome: outcome.caretContextOutcome,
      repairRules: outcome.repairRules,
      pastePayloadKind: outcome.pasteResult?.submittedPayload?.rawValue,
      // #1921: carried through unchanged. Each hop transports exactly what the
      // previous one produced — no normalising, no substituting a default —
      // because a value that is quietly rewritten in transit is worse than one
      // that is dropped: the dropped one is visibly absent.
      languageResolutionSource: outcome.languageResolutionSource,
      languageConfidenceBucket: outcome.languageConfidenceBucket,
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
      stopWhileDecodeInFlight: telemetryState.asrCompletedTelemetry?.stopWhileDecodeInFlight,
      // #1914: copied without applying another policy. `LLMPolishStep` stamps
      // the per-attempt fact after generation and validation; empty-output
      // recovery above clears it when finalization reclassifies the result as
      // skipped. `emitFallbackFields` owns different telemetry.
      polishRanRemote: outcome.polishRanRemote
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
