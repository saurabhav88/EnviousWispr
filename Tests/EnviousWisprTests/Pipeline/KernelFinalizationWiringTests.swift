import AppKit
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation
import Testing
import os

@testable import EnviousWisprPipeline
@testable import EnviousWisprPostProcessing

// MARK: - KernelFinalizationWiringTests (epic #827, PR-4 §11.4)
//
// Unit coverage for `KernelFinalizationWiring` — the processText / store /
// deliver closures and the wedge-tuning constants. `save` / `deliverPaste`
// are fake closures so the suite touches neither disk nor the AX paste APIs.

@MainActor
@Suite struct KernelFinalizationWiringTests {

  /// A deterministic word oracle, injected through the wiring's own seam.
  ///
  /// Six cases here drive the real production repair, which needs word
  /// knowledge. This is INJECTED rather than installed into
  /// `EnglishWordOracleRuntime`: mutating that process-global would race
  /// `EnglishWordOracleTests`, which legitimately resets and latches it, and
  /// Swift Testing runs suites concurrently — a flake that passes until it does
  /// not (local diff review, P2).
  ///
  /// A FAKE rather than a real prewarm, because the live oracle reads the
  /// machine's dictionaries, part-of-speech assets and the user's learned words;
  /// gating CI on those would be flaky by construction (#1803 plan §11.2).
  static let testOracle = EnglishWordOracle(
    unavailableReason: nil,
    dictionaryVerdict: {
      ["review", "the", "store", "testing"].contains($0) ? .ordinary : .notOrdinary
    },
    isLearnedWord: { _ in false },
    isRecognizedName: { _, _ in false })

  // MARK: Wedge tuning (PR-4 §3.6)

  @Test("wedge tuning is precedent-derived: 10 ticks x 100ms = a 1.0s window")
  func wedgeTuning() {
    #expect(KernelFinalizationWiring.wedgeStallTicks == 10)
    #expect(KernelFinalizationWiring.tickDurationSeconds == 0.1)
    // 1.0 s window >= LoadProgressWatcher's 0.8 s silence floor.
    let windowSeconds =
      Double(KernelFinalizationWiring.wedgeStallTicks)
      * KernelFinalizationWiring.tickDurationSeconds
    #expect(windowSeconds >= 0.8)
  }

  @Test(
    "currentTick advances by the number of whole logical ticks elapsed",
    .bug(
      "https://github.com/saurabhav88/EnviousWispr/issues/900",
      "logical tick rate was unverified (tautology)"
    )
  )
  func currentTickAdvancesWithClock() async {
    // Inject a manual clock so logical time advances by hand — no Task.sleep
    // cadence (`tests-no-real-time-scheduling-precision`). The old test asserted
    // `first == currentTick() || currentTick() >= first`, true for any monotonic
    // or even frozen clock, so a frozen clock or wrong tick divisor passed.
    let clock = ManualClock()
    let wiring = makeWiring(currentTime: { clock.now })
    let first = wiring.currentTick()  // floor(0 / 0.1) == 0

    // Advance 3.5 ticks: landing mid-window means floating-point error in
    // `UInt64(now / tickDurationSeconds)` cannot straddle a tick boundary, so
    // exactly 3 whole ticks have elapsed. (Advancing a clean 3.0 ticks would
    // rely on the lucky rounding of `0.1 * 3 / 0.1`; 3.5 is boundary-safe.)
    clock.advance(by: KernelFinalizationWiring.tickDurationSeconds * 3.5)
    #expect(wiring.currentTick() == first + 3)

    await wiring.sleepTicks(0)  // a zero-tick sleep returns promptly (liveness)
  }

  // MARK: processText

  @Test("processText runs the limb chain and writes the polish side-channel")
  func processTextWritesSideChannel() async throws {
    let outcome = KernelFinalizationOutcome()
    let wiring = makeWiring(outcome: outcome)
    // ITN-transformable input: if the limb chain were bypassed (raw text passed
    // straight through, side-channel set to raw), both assertions would read
    // "the code is two zero three". The chain actually running formats it to
    // "the code is 203", so the exact-match assertions pin real limb work — the
    // old `!isEmpty` + `!= nil` pair stayed green under a full bypass.
    let result = try await wiring.processText("the code is two zero three") {}
    #expect(result == "the code is 203")
    #expect(
      outcome.rawText == "the code is 203",
      "the post-chain floor text is recorded on the side channel for the store closure")
  }

  @Test("processText wires onPolishStarted into LLMPolishStep.onWillProcess")
  func processTextWiresPolishSignal() async throws {
    let steps = makeSteps()
    let wiring = makeWiring(steps: steps)
    let signal = SignalFlag()
    _ = try await wiring.processText("hello") { signal.fired = true }
    // The closure is now installed on the polish step — the limb emits, the
    // kernel observes (D18 closed, PR-4 §3.8).
    steps.llmPolish.onWillProcess?()
    #expect(signal.fired)
  }

  // MARK: ITN floor (#145)

  @Test("ITN runs in the live chain: spoken numbers are formatted (floor on)")
  func itnFormatsInChain() async throws {
    let outcome = KernelFinalizationOutcome()
    let wiring = makeWiring(outcome: outcome)
    // Polish is OFF in this harness (no API key) → the chain's final text is
    // the post-ITN text = the raw-fallback floor.
    let result = try await wiring.processText("the code is two zero three") {}
    #expect(result == "the code is 203")
    #expect(outcome.itnRan)
    #expect(outcome.itnChanged)
    #expect(outcome.itnSkipReason == nil)
  }

  @Test("ITN floor is delivered end-to-end: metrics flag the polish-off floor")
  func itnFloorDeliveredMetrics() async throws {
    let outcome = KernelFinalizationOutcome()
    let saved = SavedTranscriptBox()
    let context = KernelSessionContext()
    context.config = .testDefault(autoPasteToActiveApp: true)
    let wiring = makeWiring(outcome: outcome, context: context, save: { saved.transcript = $0 })

    let floored = try await wiring.processText(
      "call me at two zero three nine five four eight eight seven nine"
    ) {}
    try await wiring.store(floored, UUID())
    _ = await wiring.deliver(floored)

    let metrics = try #require(outcome.transcript?.metrics)
    #expect(metrics.itnRan == true)
    #expect(metrics.itnChanged == true)
    #expect(metrics.itnFloorDelivered == true, "polish off + ITN changed => the user got the floor")
    #expect(metrics.itnSkipReason == nil)
    #expect((metrics.itnLenBefore ?? 0) > 0)
  }

  @Test("plain prose is a no-op: ITN ran, changed nothing, floor not delivered")
  func itnNoOpPassthrough() async throws {
    let outcome = KernelFinalizationOutcome()
    let saved = SavedTranscriptBox()
    let context = KernelSessionContext()
    context.config = .testDefault(autoPasteToActiveApp: true)
    let wiring = makeWiring(outcome: outcome, context: context, save: { saved.transcript = $0 })

    let result = try await wiring.processText("hello there friend") {}
    try await wiring.store(result, UUID())
    _ = await wiring.deliver(result)

    #expect(result == "hello there friend")
    let metrics = try #require(outcome.transcript?.metrics)
    #expect(metrics.itnRan == true)
    #expect(metrics.itnChanged == false)
    #expect(metrics.itnFloorDelivered == false)
  }

  @Test("chain order: filler removal runs BEFORE ITN")
  func itnRunsAfterFillerRemoval() async throws {
    let steps = makeSteps()
    steps.fillerRemoval.fillerRemovalEnabled = true
    let outcome = KernelFinalizationOutcome()
    let wiring = makeWiring(outcome: outcome, steps: steps)
    // The output "the code is 203" is order-INSENSITIVE — both orders reach it —
    // so it cannot prove the chain order. The real proof is the length ITN
    // recorded for its input: filler removal runs first and strips the leading
    // "um ", so ITN sees the 26-char cleaned text. If ITN ran before filler
    // removal it would see the 29-char raw ("um " still present) and lenBefore
    // would be 3 longer.
    let result = try await wiring.processText("um the code is two zero three") {}
    #expect(result == "the code is 203")
    #expect(outcome.itnLenBefore == "the code is two zero three".count)
  }

  @Test("per-session gate wire reads the engine LID capability, not an identity literal")
  func itnBackendCapabilityWired() async throws {
    let steps = makeSteps()
    let wiring = makeWiring(steps: steps)
    _ = try await wiring.processText("hello") {}
    // The Parakeet-class adapter does not support LID → the step's gate hint is
    // wired to false (run on English-or-unknown), sourced from
    // `adapter.capabilities.supportsLanguageDetection`.
    #expect(steps.inverseTextNormalization.backendSupportsLID == false)
  }

  @Test(
    "itn_floor_delivered is true whenever polish did not deliver a distinct result",
    arguments: [
      // (itnChanged, polished, raw, fellBack, expected)
      (false, String?.none, String?.some("203"), false, false),  // ITN didn't change → never
      (true, String?.none, String?.some("203"), false, true),  // disabled or too-short bypass → floor
      (true, String?.some("203"), String?.some("203"), true, true),  // rejected → floor
      (true, String?.some("203"), String?.some("203"), false, true),  // ran-but-identical (==) → floor
      (true, String?.some("Two oh three"), String?.some("203"), false, false),  // distinct polish → not floor
    ])
  func floorDeliveredLogic(
    itnChanged: Bool, polished: String?, raw: String?, fellBack: Bool, expected: Bool
  ) {
    #expect(
      KernelFinalizationWiring.itnFloorDelivered(
        itnChanged: itnChanged, polishedText: polished, rawText: raw,
        pipelineFellBackToRaw: fellBack) == expected)
  }

  // MARK: store

  @Test(
    "short dictation through the real chain persists no polish output and no provider stamp",
    .bug(
      "https://github.com/saurabhav88/EnviousWispr/issues/1022",
      "AI badge on short dictations AI never touched"
    )
  )
  func shortDictationStoresBypass() async throws {
    let outcome = KernelFinalizationOutcome()
    let saved = SavedTranscriptBox()
    let steps = makeSteps()
    // Polish ON (provider + mocked polisher) so the nil comes from the
    // too-short gate, not from the disabled-step path the other tests use.
    steps.llmPolish.llmProvider = .openAI
    steps.llmPolish.llmModel = "gpt-4o-mini"
    steps.llmPolish.makePolisher = { _, _, _ in CannedPolisher() }
    let wiring = makeWiring(outcome: outcome, steps: steps, save: { saved.transcript = $0 })

    let result = try await wiring.processText("Other apps") {}
    try await wiring.store(result, UUID())

    // The unit-level proxy for "history row shows no AI badge" (#1022).
    let transcript = try #require(saved.transcript)
    #expect(transcript.text == "Other apps")
    #expect(transcript.polishedText == nil)
    #expect(transcript.llmProvider == nil)
    #expect(transcript.llmModel == nil)
  }

  @Test("store builds the Transcript from the side-channel and persists it")
  func storeBuildsAndSaves() async throws {
    let outcome = KernelFinalizationOutcome()
    outcome.rawText = "raw asr text"
    outcome.polishedText = "polished text"
    outcome.llmProvider = "openai"
    outcome.llmModel = "gpt-4o-mini"
    let saved = SavedTranscriptBox()
    let wiring = makeWiring(outcome: outcome, save: { saved.transcript = $0 })

    try await wiring.store("polished text", UUID())

    #expect(saved.transcript?.text == "raw asr text")
    #expect(saved.transcript?.polishedText == "polished text")
    #expect(saved.transcript?.backendType == .parakeet)
    #expect(saved.transcript?.llmProvider == "openai")
    #expect(outcome.transcript?.text == "raw asr text", "the driver reads the transcript here")
    // #1167: a clean save marks the outcome saved and clears any prior error.
    #expect(outcome.historySaved)
    #expect(outcome.historySaveError == nil)
  }

  @Test(
    "store absorbs a storage failure: records it on the outcome + telemetry, does NOT throw (#1167)",
    .bug(
      "https://github.com/saurabhav88/EnviousWispr/issues/1167",
      "a history-save throw must not abort delivery"
    )
  )
  func storeAbsorbsStorageFailure() async throws {
    let outcome = KernelFinalizationOutcome()
    outcome.rawText = "the delivered words"
    let telemetryState = KernelTelemetryState()
    let wiring = makeWiring(
      outcome: outcome,
      save: { _ in throw WiringTestError.storage },
      telemetryState: telemetryState)
    // Best-effort: the save throw is absorbed — `store` does NOT propagate it,
    // so the kernel proceeds to deliver instead of routing a terminal failure.
    try await wiring.store("the delivered words", UUID())
    #expect(outcome.historySaved == false)
    #expect(outcome.historySaveError != nil)
    // The transcript is set BEFORE the save attempt, so completion telemetry +
    // paste metrics populate and delivery proceeds with the polished text.
    #expect(outcome.transcript?.text == "the delivered words")
    // Mirrored onto the telemetry side-channel so the lifecycle sink withholds
    // the "transcript durably saved" success marker.
    #expect(telemetryState.historySaveFailed)
  }

  // MARK: emoji-restore telemetry never leaks across dictations (#761)

  @Test(
    "emoji telemetry from a prior AFM dictation never rides a later non-emoji transcript (#761)")
  func emojiTelemetryClearsOnNonAFM() async throws {
    // The reused outcome carries a prior AFM dictation's stamped emoji counts.
    let outcome = KernelFinalizationOutcome()
    outcome.emojiRan = true
    outcome.emojiInInput = 2
    outcome.emojiDropped = 2
    outcome.emojiRestored = 2
    outcome.emojiLatencyMs = 0.1
    // This harness runs polish OFF → the dictation is non-AFM → the always-on
    // step clears its own `lastRun` → the wiring must RESET the stale outcome
    // rather than leave the prior counts attached to this transcript.
    let wiring = makeWiring(outcome: outcome)
    _ = try await wiring.processText("the code is two zero three") {}
    #expect(outcome.emojiRan == false)
    #expect(outcome.emojiInInput == nil)
    #expect(outcome.emojiDropped == nil)
    #expect(outcome.emojiRestored == nil)
    #expect(outcome.emojiLatencyMs == nil)
  }

  // MARK: deliver

  @Test("deliver pastes when auto-paste is on and the cascade delivered")
  func deliverPastes() async {
    let context = KernelSessionContext()
    context.config = .testDefault(autoPasteToActiveApp: true)
    let wiring = makeWiring(context: context, deliverPaste: { _ in Self.deliveredResult })
    let outcome = await wiring.deliver("hello")
    #expect(outcome == .pasted)
  }

  @Test("deliver reports clipboardOnly when the cascade fell back")
  func deliverClipboardFallback() async {
    let context = KernelSessionContext()
    context.config = .testDefault(autoPasteToActiveApp: true)
    let wiring = makeWiring(context: context, deliverPaste: { _ in Self.clipboardResult })
    let outcome = await wiring.deliver("hello")
    #expect(outcome == .clipboardOnly)
  }

  @Test("deliver reports clipboardOnly for a copy-to-clipboard-only session")
  func deliverCopyOnly() async {
    let context = KernelSessionContext()
    context.config = .testDefault(autoCopyToClipboard: true, autoPasteToActiveApp: false)
    let wiring = makeWiring(context: context, deliverPaste: { _ in Self.deliveredResult })
    let outcome = await wiring.deliver("hello")
    #expect(outcome == .clipboardOnly, "no auto-paste => never .pasted")
  }

  @Test("#1921 A clipboard-only delivery cannot inherit the previous session's language fields")
  func clipboardOnlyDeliveryClearsStaleLanguageFields() async {
    // `outcome` is SHARED and reused across sessions, and everything describing
    // the insertion repair is written inside the auto-paste branch. So a
    // clipboard-only delivery skips those assignments entirely.
    //
    // Without a default written at the top of `deliver`, this session would
    // report the PREVIOUS dictation's language decision as if it were its own —
    // stale telemetry that is indistinguishable from a real reading in the
    // field, which is the worst kind. Found by chunk review; the first version
    // of the production comment claimed these were "written on EVERY path".
    let outcome = KernelFinalizationOutcome()
    outcome.languageResolutionSource = "dictation"
    outcome.languageConfidenceBucket = "ge90"

    let context = KernelSessionContext()
    context.config = .testDefault(autoCopyToClipboard: true, autoPasteToActiveApp: false)
    let wiring = makeWiring(
      outcome: outcome, context: context, deliverPaste: { _ in Self.deliveredResult })

    _ = await wiring.deliver("hello")

    #expect(
      outcome.languageResolutionSource == nil,
      "a clipboard-only session never reaches the resolver, so nothing was MEASURED")
    #expect(
      outcome.languageConfidenceBucket == nil,
      "nil means no attempt; \"none\" would claim an attempt that produced no answer")
  }

  // MARK: - Contracts migrated to the live finalization wiring
  //
  // The retired test-only seam was never constructed by shipped code, so its
  // contract tests proved nothing about production. Each still-valid contract
  // now runs against the live wiring, where a regression in the real delivery
  // path actually fails.

  @Test("a limb failure preserves the raw ASR text and still saves exactly once")
  func limbFailurePreservesRawTextAndSavesOnce() async throws {
    // A polish throw is the realistic limb failure; the chain surfaces it and
    // the heart path still delivers the raw words.
    let outcome = KernelFinalizationOutcome()
    let saves = SaveCountBox()
    let polish = LLMPolishStep(keychainManager: KeychainManager())
    polish.llmProvider = .openAI
    polish.makePolisher = { _, _, _ in ThrowingPolisher() }
    let wiring = makeWiring(
      outcome: outcome,
      steps: makeSteps(polish: polish),
      save: {
        saves.count += 1
        saves.last = $0
      })

    // 4+ words: production's `LLMPolishStep` skips polish at 3 words or fewer
    // (`minWordsForPolish`), so a shorter input would never reach the polisher
    // and the limb could not fail at all.
    let text = try await wiring.processText("hello world this is a test") {}
    try await wiring.store(text, UUID())

    #expect(text == "hello world this is a test", "raw ASR text survives a limb failure")
    #expect(outcome.polishedText == nil)
    #expect(outcome.polishError != nil, "polish surfaces its error")
    #expect(saves.count == 1)
    #expect(saves.last?.text == "hello world this is a test")
  }

  @Test("whitespace-only chain output reaches the kernel's empty guard unchanged")
  func whitespaceOnlyOutputIsNotGuardedAtThisLayer() async throws {
    // The deleted seam threw `.emptyAfterProcessing` here. In production that
    // guard lives one layer up, in `RecordingSessionKernel` (the
    // `processed.trimmingCharacters(...).isEmpty` check that finishes
    // `.noSpeech(.emptyAfterProcessing)` BEFORE store or deliver runs). This
    // pins the wiring's half of that contract: it passes the text through
    // without inventing an error type. The terminal mapping itself is covered by
    // KernelLifecycleTelemetrySinkTests and TerminalNoticeReasonMappingTests.
    let saves = SaveCountBox()
    let wiring = makeWiring(save: { _ in saves.count += 1 })

    let text = try await wiring.processText("   \n\t  ") {}

    #expect(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    #expect(saves.count == 0, "the wiring does not save on its own; the kernel gates first")
  }

  @Test(
    "a storage failure is absorbed and delivery still runs exactly once with the legacy payload")
  func storageFailureStillDeliversExactlyOnce() async throws {
    // REPLACES two obsolete contracts from the dead seam:
    // `storeThrowWrapsAsStorageFailed` (a typed .storageFailed wrap) and
    // `storeFailureShortCircuitsPaste` (store failure aborted the paste).
    // Production reversed the second one deliberately in #1167: storage is
    // best-effort and MUST NOT cost the user their delivery. Proven end to end
    // here — store then deliver — rather than as two isolated tests.
    let outcome = KernelFinalizationOutcome()
    outcome.rawText = "hello world"
    let telemetryState = KernelTelemetryState()
    let saveAttempts = SaveCountBox()
    let delivered = DeliveredPayloadBox()
    let context = KernelSessionContext()
    context.config = .testDefault(autoPasteToActiveApp: true)
    let wiring = makeWiring(
      outcome: outcome,
      context: context,
      save: { _ in
        saveAttempts.count += 1
        throw WiringTestError.storage
      },
      deliverPaste: { request in
        delivered.payloads.append(request.legacyText)
        return Self.deliveredResult
      },
      telemetryState: telemetryState)

    try await wiring.store("hello world", UUID())
    let deliveryOutcome = await wiring.deliver("hello world")

    #expect(saveAttempts.count == 1, "the save was attempted exactly once")
    #expect(outcome.historySaved == false)
    #expect(outcome.historySaveError != nil)
    #expect(telemetryState.historySaveFailed, "the lifecycle sink must see the degraded save")
    #expect(outcome.transcript?.text == "hello world", "the side-channel survives for delivery")
    #expect(deliveryOutcome == .pasted)
    #expect(
      delivered.payloads == ["hello world "],
      "delivery runs exactly once, with the legacy trailing space appended exactly once")
  }

  @Test("a clipboard-only cascade result is non-fatal and still completes delivery")
  func clipboardOnlyIsNonFatal() async throws {
    let outcome = KernelFinalizationOutcome()
    let context = KernelSessionContext()
    context.config = .testDefault(autoPasteToActiveApp: true)
    let wiring = makeWiring(
      outcome: outcome, context: context,
      deliverPaste: { _ in Self.clipboardResult })

    let deliveryOutcome = await wiring.deliver("paste me")

    #expect(deliveryOutcome == .clipboardOnly)
    #expect(outcome.pasteResult?.tier == .clipboardOnly)
  }

  @Test("a cancellation-like limb preserves raw text and still saves and delivers once")
  func cancellationLikeLimbStillStoresAndDeliversOnce() async throws {
    // The runner's `isCancellationLike` classification is covered by its own
    // suite, but classification alone does not prove the heart path survives.
    // This pins the consequence at the live boundary: raw text preserved, saved
    // once, delivered once, no duplicate and no loss.
    let outcome = KernelFinalizationOutcome()
    let saves = SaveCountBox()
    let delivered = DeliveredPayloadBox()
    let context = KernelSessionContext()
    context.config = .testDefault(autoPasteToActiveApp: true)

    let polish = LLMPolishStep(keychainManager: KeychainManager())
    polish.llmProvider = .openAI
    polish.makePolisher = { _, _, _ in CancellingPolisher() }

    let wiring = makeWiring(
      outcome: outcome,
      context: context,
      steps: makeSteps(polish: polish),
      save: {
        saves.count += 1
        saves.last = $0
      },
      deliverPaste: { request in
        delivered.payloads.append(request.legacyText)
        return Self.deliveredResult
      })

    let raw = "hello world this is a test"
    let processed = try await wiring.processText(raw) {}
    try await wiring.store(processed, UUID())
    let delivery = await wiring.deliver(processed)

    #expect(processed == raw)
    #expect(
      outcome.polishError == nil,
      "a cancellation-like failure is absorbed silently, not surfaced to the user")
    #expect(saves.count == 1)
    #expect(saves.last?.text == raw)
    #expect(delivery == .pasted)
    #expect(delivered.payloads == ["hello world this is a test "])
  }

  // MARK: - Paste-completion event gating (migrated, #640)

  private final class CapturingObserver: PasteCompletionObserver {
    var events: [PasteCompletionEvent] = []
    func pasteCompleted(_ event: PasteCompletionEvent) { events.append(event) }
  }

  @Test("a delivered paste emits exactly one completion event carrying the pasted payload")
  func completionEventOnDelivered() async {
    let registry = PasteCompletionRegistry()
    let observer = CapturingObserver()
    registry.subscribe(observer)
    let context = KernelSessionContext()
    context.config = .testDefault(autoPasteToActiveApp: true)
    let wiring = makeWiring(
      context: context, deliverPaste: { _ in Self.deliveredResult }, registry: registry)

    _ = await wiring.deliver("hello")

    #expect(observer.events.count == 1)
    #expect(observer.events.first?.pastedText == "hello ")
  }

  @Test("the completion event carries the payload the route actually committed")
  func completionEventCarriesTheDeliveredPayload() async throws {
    // #629's subscriber watches for edits to the pasted text and learns custom
    // words from them. Announcing the legacy payload after a route committed the
    // repaired one would make our own spacing and casing read as the user
    // correcting us — teaching the app from its own output.
    let registry = PasteCompletionRegistry()
    let observer = CapturingObserver()
    registry.subscribe(observer)
    let context = KernelSessionContext()
    context.config = .testDefault(autoPasteToActiveApp: true, smartInsertion: true)
    context.targetElement = Self.stubCaretElement()
    let wiring = makeWiring(
      context: context,
      deliverPaste: { _ in
        PasteDeliveryResult(
          tier: .cgEvent, durationMs: 5,
          outcome: .delivered(tier: .cgEvent, durationMs: 5),
          submittedPayload: .repaired)
      },
      registry: registry,
      readCaretContext: { _, _, _ in Self.midSentenceCaret },
      englishWordOracle: { Self.testOracle })

    let processed = try await wiring.processText("Review this before the meeting") {}
    _ = await wiring.deliver(processed)

    let event = try #require(observer.events.first)
    #expect(
      event.pastedText == "review this before the meeting ",
      "the repaired payload landed, so that is what the observer must be told")
  }

  @Test("a route that submitted today's payload still announces today's payload")
  func completionEventFallsBackToLegacy() async throws {
    let registry = PasteCompletionRegistry()
    let observer = CapturingObserver()
    registry.subscribe(observer)
    let context = KernelSessionContext()
    context.config = .testDefault(autoPasteToActiveApp: true, smartInsertion: true)
    context.targetElement = Self.stubCaretElement()
    let wiring = makeWiring(
      context: context,
      deliverPaste: { _ in
        PasteDeliveryResult(
          tier: .cgEvent, durationMs: 5,
          outcome: .delivered(tier: .cgEvent, durationMs: 5),
          submittedPayload: .legacy)
      },
      registry: registry,
      readCaretContext: { _, _, _ in Self.midSentenceCaret },
      englishWordOracle: { Self.testOracle })

    let processed = try await wiring.processText("Review this before the meeting") {}
    _ = await wiring.deliver(processed)

    let event = try #require(observer.events.first)
    #expect(event.pastedText == "Review this before the meeting ")
  }

  @Test("a clipboard-only fallback emits no completion event")
  func completionEventSilentOnClipboardOnly() async {
    // Phase 7 auto-learn would otherwise watch a destination where nothing landed.
    let registry = PasteCompletionRegistry()
    let observer = CapturingObserver()
    registry.subscribe(observer)
    let context = KernelSessionContext()
    context.config = .testDefault(autoPasteToActiveApp: true)
    let wiring = makeWiring(
      context: context, deliverPaste: { _ in Self.clipboardResult }, registry: registry)

    _ = await wiring.deliver("hello")

    #expect(observer.events.isEmpty)
  }

  @Test("the copy-only branch emits no completion event and never calls the cascade")
  func completionEventSilentOnCopyOnly() async {
    let priorSnapshot = PasteService.saveClipboard()
    var endChangeCount = NSPasteboard.general.changeCount
    defer { Self.restorePasteboard(priorSnapshot, expectedChangeCount: endChangeCount) }

    let registry = PasteCompletionRegistry()
    let observer = CapturingObserver()
    registry.subscribe(observer)
    let context = KernelSessionContext()
    context.config = .testDefault(autoCopyToClipboard: true, autoPasteToActiveApp: false)
    let wiring = makeWiring(
      context: context,
      deliverPaste: { _ in
        Issue.record("the cascade must not run on the copy-only path")
        return Self.deliveredResult
      },
      registry: registry)

    _ = await wiring.deliver("hello")
    endChangeCount = NSPasteboard.general.changeCount

    #expect(observer.events.isEmpty)
  }

  // MARK: - Clipboard wiring (migrated, #726)

  @Test(
    "the restore-clipboard flag is forwarded to the paste request exactly",
    arguments: [true, false])
  func restoreFlagForwards(_ restore: Bool) async {
    let captured = RestoreFlagBox()
    let context = KernelSessionContext()
    context.config = .testDefault(
      autoPasteToActiveApp: true, restoreClipboardAfterPaste: restore)
    let wiring = makeWiring(
      context: context,
      deliverPaste: { request in
        captured.value = request.restoreClipboardAfterPaste
        return Self.deliveredResult
      })

    _ = await wiring.deliver("hello")

    #expect(captured.value == restore)
  }

  @Test("copy-only writes the DISPLAY text to the clipboard, never the raw ASR text")
  func copyOnlyWritesDisplayText() async {
    let pasteboard = NSPasteboard.general
    let priorSnapshot = PasteService.saveClipboard()
    let sentinel = "issue-726-prior-\(UUID().uuidString)"
    pasteboard.clearContents()
    pasteboard.setString(sentinel, forType: .string)
    var endChangeCount = pasteboard.changeCount
    defer { Self.restorePasteboard(priorSnapshot, expectedChangeCount: endChangeCount) }

    let polished = "POLISHED-\(UUID().uuidString)"
    let context = KernelSessionContext()
    context.config = .testDefault(autoCopyToClipboard: true, autoPasteToActiveApp: false)
    let wiring = makeWiring(
      context: context,
      deliverPaste: { _ in
        Issue.record("the cascade must not run when auto-paste is off")
        return Self.deliveredResult
      })

    _ = await wiring.deliver(polished)
    endChangeCount = pasteboard.changeCount

    let after = pasteboard.string(forType: .string)
    #expect(after == polished, "the clipboard must carry the display text")
    #expect(after != sentinel, "the sentinel must have been replaced")
  }

  @Test("with both auto-paste and auto-copy off the clipboard is left untouched")
  func neitherFlagTouchesClipboard() async {
    let pasteboard = NSPasteboard.general
    let priorSnapshot = PasteService.saveClipboard()
    let sentinel = "issue-726-untouched-\(UUID().uuidString)"
    pasteboard.clearContents()
    pasteboard.setString(sentinel, forType: .string)
    var endChangeCount = pasteboard.changeCount
    defer { Self.restorePasteboard(priorSnapshot, expectedChangeCount: endChangeCount) }

    let context = KernelSessionContext()
    context.config = .testDefault(autoCopyToClipboard: false, autoPasteToActiveApp: false)
    let wiring = makeWiring(
      context: context,
      deliverPaste: { _ in
        Issue.record("the cascade must not run when auto-paste is off")
        return Self.deliveredResult
      })

    _ = await wiring.deliver("hello")
    endChangeCount = pasteboard.changeCount

    #expect(pasteboard.string(forType: .string) == sentinel)
  }

  /// Restore the pasteboard ONLY if nothing else wrote to it after our last
  /// mutation. Mirrors the production `restoreClipboard` guard: a change count
  /// past what we expect means a third-party tool owns the clipboard now.
  private static func restorePasteboard(
    _ snapshot: ClipboardSnapshot?, expectedChangeCount: Int
  ) {
    guard let snapshot else { return }
    PasteService.restoreClipboard(snapshot, changeCountAfterPaste: expectedChangeCount)
  }

  // MARK: Helpers

  private static let deliveredResult = PasteDeliveryResult(
    tier: .cgEvent, durationMs: 5,
    outcome: .delivered(tier: .cgEvent, durationMs: 5))

  private static let clipboardResult = PasteDeliveryResult(
    tier: .clipboardOnly, durationMs: 1,
    outcome: .clipboardOnlyAccessibilityDenied(targetBundleID: nil))

  // MARK: - Dual-payload composition (#1785 Chunk 6)
  //
  // `deliver` now composes BOTH payloads and hands the caret evidence along
  // with them, so a later route-local decision can revalidate against the same
  // reading rather than reading the field a second time and getting a different
  // answer.
  //
  // These tests drive the real `KernelFinalizationWiring` and inspect what the
  // injected delivery seam actually received. Constructing payloads in the test
  // and comparing them would prove nothing about the production path.

  /// A caret element the injected reader can be handed. Its identity is all
  /// that matters — the reader is a fake and never touches the real field.
  private static func stubCaretElement() -> AXUIElement {
    AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
  }

  /// An engine that has already transcribed, which is the only state delivery
  /// runs in: the text being delivered exists BECAUSE a result was produced.
  /// A pre-finalize adapter reports no language, and the repair reads a missing
  /// language as "unknown" and declines to recase — correct behaviour against a
  /// state production cannot reach, and a misleading test if left in place.
  private static func transcribedEngine(language: String? = "en") -> FakeEngine {
    let engine = FakeEngine(behavior: .batchSuccess(text: ""), clock: FakeClock())
    engine.lastResult = ASRResult(
      text: "", language: language, duration: 0, processingTime: 0, backendType: .parakeet)
    return engine
  }

  private static let midSentenceCaret = PasteService.CaretContext(
    leftWindow: "I went to the ",
    rightWindow: "",
    selectionLocation: 14,
    selectionLength: 0,
    // The window is as long as the caret's offset, so it began at the field's
    // own start — the value Pipeline used to derive from exactly that test.
    leftReachesDocumentStart: true)

  @Test(
    "delivery carries today's payload, the contextual candidate, and the caret evidence")
  func deliveryTransportsBothPayloadsAndTheCaretEvidence() async throws {
    let captured = DeliveryRequestBox()
    let saved = SavedTranscriptBox()
    let context = KernelSessionContext()
    context.config = .testDefault(autoPasteToActiveApp: true, smartInsertion: true)
    context.targetElement = Self.stubCaretElement()
    let wiring = makeWiring(
      context: context,
      save: { saved.transcript = $0 },
      deliverPaste: { request in
        captured.requests.append(request)
        return Self.deliveredResult
      },
      readCaretContext: { _, _, _ in Self.midSentenceCaret },
      englishWordOracle: { Self.testOracle })

    let processed = try await wiring.processText("Review this before the meeting") {}
    try await wiring.store(processed, UUID())
    _ = await wiring.deliver(processed)

    #expect(captured.requests.count == 1, "delivery still runs exactly once")
    let request = try #require(captured.requests.first)
    // Today's payload is unchanged and always present, so a route that cannot
    // use the candidate has the correct fallback already in hand.
    #expect(request.legacyText == "Review this before the meeting ")
    // The candidate lowercases the leading word: the caret sits mid-sentence
    // after "the ", and "review" is an ordinary lowercase word.
    #expect(
      request.repairedText == "review this before the meeting ",
      "the contextual candidate must reach delivery, not be recomputed there")
    // The evidence the candidate was computed FROM travels with it.
    #expect(request.caretContext == Self.midSentenceCaret)
  }

  // The language the repair acts on is RESOLVED, not read off the engine's
  // result, and this proves it through the production wiring.
  //
  // The simulator stands in for Parakeet: `supportsLanguageDetection == false`
  // and a hard-coded `"en"` on every result, which is exactly what the real
  // backend does while transcribing 25 European languages. Believing that field
  // recased German dictations with English rules on the DEFAULT engine (cloud
  // review, PR #1802).
  @Test("German text is not recased even when the engine claims English")
  func germanTextIsNotRecasedOnAnEnglishClaimingEngine() async throws {
    let captured = DeliveryRequestBox()
    let context = KernelSessionContext()
    context.config = .testDefault(autoPasteToActiveApp: true, smartInsertion: true)
    context.targetElement = Self.stubCaretElement()
    let wiring = makeWiring(
      context: context,
      deliverPaste: { request in
        captured.requests.append(request)
        return Self.deliveredResult
      },
      readCaretContext: { _, _, _ in
        PasteService.CaretContext(
          leftWindow: "Ich gehe zum ", rightWindow: "", selectionLocation: 13,
          selectionLength: 0, leftReachesDocumentStart: true)
      },
      adapter: Self.transcribedEngine(language: "en"))

    // Long enough to identify, and unambiguous. `Start` is an ordinary English
    // lowercase word AND a German noun — the collision the language gate exists
    // for.
    let processed = try await wiring.processText(
      "Start ist heute Abend und danach gehen wir in die Stadt"
    ) {}
    _ = await wiring.deliver(processed)

    let request = try #require(captured.requests.first)
    let delivered = request.repairedText ?? request.legacyText
    #expect(
      delivered.hasPrefix("Start"),
      "a German noun must keep its capital even though the engine reported English")
  }

  // Seam de-duplication, checked through the REAL delivery composition (#1803).
  //
  // The unit table in `CursorInsertionRepairTests` proves the rule's logic with
  // hand-built arguments. It cannot prove the rule is wired to the right INPUT,
  // and that is exactly the class that escaped #1785's eight local rounds, four
  // apps of live UAT and 4,000 tests: a language gate reading a hard-coded "en",
  // caught only by cloud review. These drive the actual `deliver` closure.
  @Test("a word repeated across the seam is delivered once")
  func duplicateSeamWordIsDroppedThroughTheRealComposition() async throws {
    let captured = DeliveryRequestBox()
    let context = KernelSessionContext()
    context.config = .testDefault(autoPasteToActiveApp: true, smartInsertion: true)
    context.targetElement = Self.stubCaretElement()
    let wiring = makeWiring(
      context: context,
      deliverPaste: { request in
        captured.requests.append(request)
        return Self.deliveredResult
      },
      readCaretContext: { _, _, _ in
        PasteService.CaretContext(
          leftWindow: "I want to go to the ", rightWindow: "", selectionLocation: 20,
          selectionLength: 0, leftReachesDocumentStart: true)
      },
      adapter: Self.transcribedEngine(language: "en"))

    let processed = try await wiring.processText(
      "The store is closed today and I will go tomorrow instead"
    ) {}
    _ = await wiring.deliver(processed)

    let request = try #require(captured.requests.first)
    let repaired = try #require(request.repairedText)
    #expect(
      repaired.hasPrefix("store"),
      "the duplicated determiner must be gone, leaving: \(repaired)")
    #expect(!repaired.lowercased().hasPrefix("the "))
  }

  @Test("a locked unsegmented language refuses the drop even with a space in the text")
  func lockedJapaneseRefusesTheDrop() async throws {
    // Proves the rule reads the RESOLVED language rather than the presence of a
    // space. An English reading of this text would find a word boundary and a
    // matching leading token.
    let captured = DeliveryRequestBox()
    let context = KernelSessionContext()
    context.config = .testDefault(
      autoPasteToActiveApp: true, smartInsertion: true, languageMode: .locked("ja"))
    context.targetElement = Self.stubCaretElement()
    let wiring = makeWiring(
      context: context,
      deliverPaste: { request in
        captured.requests.append(request)
        return Self.deliveredResult
      },
      readCaretContext: { _, _, _ in
        PasteService.CaretContext(
          leftWindow: "\u{4ECA}\u{65E5}", rightWindow: "", selectionLocation: 2,
          selectionLength: 0, leftReachesDocumentStart: true)
      },
      adapter: Self.transcribedEngine(language: "ja"))

    let processed = try await wiring.processText("\u{4ECA}\u{65E5} \u{6674}\u{308C}") {}
    _ = await wiring.deliver(processed)

    let request = try #require(captured.requests.first)
    let delivered = request.repairedText ?? request.legacyText
    #expect(
      delivered.hasPrefix("\u{4ECA}\u{65E5}"),
      "an unsegmented script has no word to de-duplicate: \(delivered)")
  }

  @Test("an unreadable caret yields no candidate, so today's payload is delivered")
  func unreadableCaretDeliversLegacyPayload() async throws {
    let captured = DeliveryRequestBox()
    let context = KernelSessionContext()
    context.config = .testDefault(autoPasteToActiveApp: true, smartInsertion: true)
    context.targetElement = Self.stubCaretElement()
    let wiring = makeWiring(
      context: context,
      deliverPaste: { request in
        captured.requests.append(request)
        return Self.deliveredResult
      },
      readCaretContext: { _, _, _ in nil })

    let processed = try await wiring.processText(
      "The store is closed today and I will go tomorrow instead"
    ) {}
    _ = await wiring.deliver(processed)

    let request = try #require(captured.requests.first)
    #expect(request.repairedText == nil)
    #expect(request.legacyText.hasPrefix("The store"))
  }

  @Test("English text on the same engine is still recased")
  func englishTextIsStillRecased() async throws {
    // The fix must not cost the majority case its feature.
    let captured = DeliveryRequestBox()
    let context = KernelSessionContext()
    context.config = .testDefault(autoPasteToActiveApp: true, smartInsertion: true)
    context.targetElement = Self.stubCaretElement()
    let wiring = makeWiring(
      context: context,
      deliverPaste: { request in
        captured.requests.append(request)
        return Self.deliveredResult
      },
      readCaretContext: { _, _, _ in Self.midSentenceCaret },
      adapter: Self.transcribedEngine(language: "en"))

    let processed = try await wiring.processText(
      "Review this before the meeting and then send it along"
    ) {}
    _ = await wiring.deliver(processed)

    let request = try #require(captured.requests.first)
    #expect(request.repairedText?.hasPrefix("review") == true)
  }

  // The read gate is a closed 2x2: the surrounding document may be read ONLY
  // when the feature is on AND there is a field to read from. All four cells are
  // enumerated rather than sampled, because three of them are silent — a read
  // that happens when it shouldn't leaves no trace in the delivered text, so
  // only a call counter can catch it. This is a privacy boundary, not a cost one.
  @Test(
    "the surrounding document is read only when the feature is on and a field exists",
    arguments: [
      (smartInsertion: true, hasTarget: true, expectedReads: 1),
      (smartInsertion: true, hasTarget: false, expectedReads: 0),
      (smartInsertion: false, hasTarget: true, expectedReads: 0),
      (smartInsertion: false, hasTarget: false, expectedReads: 0),
    ])
  func caretReadGateIsClosed(
    _ cell: (smartInsertion: Bool, hasTarget: Bool, expectedReads: Int)
  ) async {
    let reads = SaveCountBox()
    let captured = DeliveryRequestBox()
    let context = KernelSessionContext()
    context.config = .testDefault(
      autoPasteToActiveApp: true, smartInsertion: cell.smartInsertion)
    context.targetElement = cell.hasTarget ? Self.stubCaretElement() : nil
    let wiring = makeWiring(
      context: context,
      deliverPaste: { request in
        captured.requests.append(request)
        return Self.deliveredResult
      },
      readCaretContext: { _, _, _ in
        reads.count += 1
        return Self.midSentenceCaret
      })

    _ = await wiring.deliver("Review this before the meeting")

    #expect(
      reads.count == cell.expectedReads,
      "reads for on=\(cell.smartInsertion) target=\(cell.hasTarget): expected \(cell.expectedReads), got \(reads.count)"
    )
    // Every cell that does not read must deliver exactly today's payload, with
    // no candidate and no caret evidence attached.
    let request = captured.requests.first
    if cell.expectedReads == 0 {
      #expect(request?.repairedText == nil)
      #expect(request?.caretContext == nil)
    } else {
      #expect(request?.repairedText != nil)
      #expect(request?.caretContext != nil)
    }
    #expect(
      request?.legacyText == "Review this before the meeting ",
      "today's payload is delivered unchanged in every cell")
  }

  @Test("an unreadable field yields no candidate, and today's payload still ships")
  func unreadableFieldFallsBackToTodaysPayload() async {
    // The accessibility read fails open. The distinction that matters is that it
    // produces NO candidate rather than a wrong one, and never blocks delivery.
    let captured = DeliveryRequestBox()
    let context = KernelSessionContext()
    context.config = .testDefault(autoPasteToActiveApp: true, smartInsertion: true)
    context.targetElement = Self.stubCaretElement()
    let wiring = makeWiring(
      context: context,
      deliverPaste: { request in
        captured.requests.append(request)
        return Self.deliveredResult
      },
      readCaretContext: { _, _, _ in nil })

    let outcome = await wiring.deliver("Review this before the meeting")

    #expect(outcome == .pasted, "an unreadable field must never cost the user their delivery")
    #expect(captured.requests.first?.repairedText == nil)
    #expect(captured.requests.first?.caretContext == nil)
    #expect(captured.requests.first?.legacyText == "Review this before the meeting ")
  }

  @Test("a later process refreshes canonicals and aliases never protect output")
  func laterProcessRefreshesSnapshotAndExcludesAliases() async throws {
    let captured = DeliveryRequestBox()
    let context = KernelSessionContext()
    context.config = .testDefault(autoPasteToActiveApp: true, smartInsertion: true)
    context.targetElement = Self.stubCaretElement()

    let steps = makeSteps()
    steps.wordCorrection.correctorVocabulary = CorrectorVocabulary(
      terms: [CustomWord(canonical: "Review")],
      generation: 1)

    let wiring = makeWiring(
      context: context,
      steps: steps,
      deliverPaste: { request in
        captured.requests.append(request)
        return Self.deliveredResult
      },
      readCaretContext: { _, _, _ in Self.midSentenceCaret },
      englishWordOracle: { Self.testOracle })

    let first = try await wiring.processText("Review this before the meeting") {}
    _ = await wiring.deliver(first)

    steps.wordCorrection.correctorVocabulary = CorrectorVocabulary(
      terms: [CustomWord(canonical: "Other", aliases: ["Review"])],
      generation: 2)

    let second = try await wiring.processText("Review this before the meeting") {}
    _ = await wiring.deliver(second)

    try #require(captured.requests.count == 2)
    #expect(captured.requests[0].repairedText == "Review this before the meeting ")
    #expect(captured.requests[1].repairedText == "review this before the meeting ")
  }

  @Test("mid-word refusal carries its evidence but no contextual candidate")
  func midWordRefusalCarriesContextAndLegacyPayload() async throws {
    let captured = DeliveryRequestBox()
    let context = KernelSessionContext()
    context.config = .testDefault(autoPasteToActiveApp: true, smartInsertion: true)
    context.targetElement = Self.stubCaretElement()

    let midWord = PasteService.CaretContext(
      leftWindow: "sto",
      rightWindow: "re",
      selectionLocation: 3,
      selectionLength: 0,
      leftReachesDocumentStart: true)

    let wiring = makeWiring(
      context: context,
      deliverPaste: { request in
        captured.requests.append(request)
        return Self.deliveredResult
      },
      readCaretContext: { _, _, _ in midWord })

    _ = await wiring.deliver("Store today")

    let request = try #require(captured.requests.first)
    // The evidence still travels, so a route can tell a deliberate refusal apart
    // from a field it could not read at all.
    #expect(request.caretContext == midWord)
    #expect(request.repairedText == nil)
    #expect(request.legacyText == "Store today ")
  }

  @Test("input that already ends in a space is not double-spaced through the wiring")
  func alreadySpacedInputIsNotDoubleSpaced() async throws {
    // Kept separate from the gate matrix so a failure says which property broke.
    let captured = DeliveryRequestBox()
    let context = KernelSessionContext()
    context.config = .testDefault(autoPasteToActiveApp: true, smartInsertion: true)
    context.targetElement = Self.stubCaretElement()
    let wiring = makeWiring(
      context: context,
      deliverPaste: { request in
        captured.requests.append(request)
        return Self.deliveredResult
      },
      readCaretContext: { _, _, _ in Self.midSentenceCaret },
      englishWordOracle: { Self.testOracle })

    _ = await wiring.deliver("Review this before the meeting ")

    let request = try #require(captured.requests.first)
    #expect(request.legacyText == "Review this before the meeting ")
    #expect(request.repairedText == "review this before the meeting ")
  }

  @Test(
    "custom words added mid-dictation do not change a decision for text already in flight")
  func protectedSpellingsAreSnapshotAtProcessingStart() async throws {
    let captured = DeliveryRequestBox()
    let context = KernelSessionContext()
    context.config = .testDefault(autoPasteToActiveApp: true, smartInsertion: true)
    context.targetElement = Self.stubCaretElement()
    let steps = makeSteps()
    let wiring = makeWiring(
      context: context,
      steps: steps,
      deliverPaste: { request in
        captured.requests.append(request)
        return Self.deliveredResult
      },
      readCaretContext: { _, _, _ in Self.midSentenceCaret },
      englishWordOracle: { Self.testOracle })

    // The vocabulary is EMPTY while this dictation is processed, so nothing
    // protects the leading word.
    #expect(steps.wordCorrection.correctorVocabulary.terms.isEmpty)
    let processed = try await wiring.processText("Review this before the meeting") {}

    // Now the user adds "Review" as a custom word — mid-dictation, exactly what
    // `CustomWordsPropagator` does when a settings edit lands. The words the
    // user is already saying must not be re-decided under them.
    steps.wordCorrection.correctorVocabulary = CorrectorVocabulary(
      terms: [CustomWord(canonical: "Review")], generation: 1)

    _ = await wiring.deliver(processed)

    let request = try #require(captured.requests.first)
    #expect(
      request.repairedText == "review this before the meeting ",
      "the late custom word must not retroactively protect this dictation")

    // Control, so the assertion above cannot pass for the wrong reason: with the
    // SAME vocabulary present from the start, the word is protected and the
    // candidate keeps its capital.
    let secondCaptured = DeliveryRequestBox()
    let secondContext = KernelSessionContext()
    secondContext.config = .testDefault(autoPasteToActiveApp: true, smartInsertion: true)
    secondContext.targetElement = Self.stubCaretElement()
    let secondSteps = makeSteps()
    secondSteps.wordCorrection.correctorVocabulary = CorrectorVocabulary(
      terms: [CustomWord(canonical: "Review")], generation: 1)
    let secondWiring = makeWiring(
      context: secondContext,
      steps: secondSteps,
      deliverPaste: { request in
        secondCaptured.requests.append(request)
        return Self.deliveredResult
      },
      readCaretContext: { _, _, _ in Self.midSentenceCaret },
      englishWordOracle: { Self.testOracle })

    let secondProcessed = try await secondWiring.processText("Review this before the meeting") {}
    _ = await secondWiring.deliver(secondProcessed)

    let secondRequest = try #require(secondCaptured.requests.first)
    #expect(
      secondRequest.repairedText == "Review this before the meeting ",
      "a custom word present at processing time IS honoured")
  }

  // MARK: - Private helpers

  private func makeSteps(polish: LLMPolishStep? = nil) -> LimbSteps {
    LimbSteps(
      wordCorrection: WordCorrectionStep(),
      fillerRemoval: FillerRemovalStep(),
      emojiFormatter: EmojiFormatterStep(),
      inverseTextNormalization: InverseTextNormalizationStep(),
      llmPolish: polish ?? LLMPolishStep(keychainManager: KeychainManager()),
      emojiRestore: EmojiRestoreStep())
  }

  private func makeWiring(
    outcome: KernelFinalizationOutcome = KernelFinalizationOutcome(),
    context: KernelSessionContext = KernelSessionContext(),
    steps: LimbSteps? = nil,
    save: @escaping @MainActor (Transcript) throws -> Void = { _ in },
    deliverPaste: @escaping @MainActor (PasteDeliveryRequest) async -> PasteDeliveryResult = {
      _ in Self.deliveredResult
    },
    telemetryState: KernelTelemetryState = KernelTelemetryState(),
    registry: PasteCompletionRegistry? = nil,
    currentTime: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    // Defaults to UNREADABLE, so every pre-existing test in this suite keeps
    // exactly today's behaviour and only tests that opt in see a candidate.
    readCaretContext: @escaping @MainActor (
      AXUIElement, TerminalResolutionBudget, ((TerminalContextRefusal) -> Void)?
    ) -> PasteService.CaretContext? = { _, _, _ in
      nil
    },
    // Delivery only ever runs after a transcription produced the text being
    // delivered, so the adapter it reads has a result by then. The default
    // stands in for exactly that state; language tests vary the code.
    adapter: (any ASREngineAdapter)? = nil,
    // Injected, never installed into the process-global runtime: mutating that
    // would race `EnglishWordOracleTests` under concurrent suite execution.
    englishWordOracle: @escaping @MainActor () -> EnglishWordOracle = { Self.testOracle },
    // #1921 language-resolver seam. Defaults to the real resolver so every
    // pre-existing case keeps today's behaviour; the two deadline tests inject a
    // blocking one to drive the REAL 100 ms deadline into its timeout paths.
    resolveLanguage: (
      @Sendable (String?, Bool, String?, String, String) ->
        DictationLanguageResolver.Resolution
    )? = nil
  ) -> KernelFinalizationWiring {
    KernelFinalizationWiring(
      outcome: outcome,
      context: context,
      adapter: adapter ?? Self.transcribedEngine(),
      steps: steps ?? makeSteps(),
      // #989: deterministic executor — this suite asserts chain SEMANTICS
      // (ordering, side channels, delivery), never step timing. The
      // production `withThrowingTimeout` executor let full-suite MainActor
      // contention starve a short-budget limb (FillerRemoval, 50ms) past its
      // deadline, silently discarding its output and flaking the chain-order
      // test. Timeout behavior itself is covered by TextProcessingRunnerTests
      // and HeartPathIntegrationTests with the same fake.
      textProcessingRunner: TextProcessingRunner(
        timeoutExecutor: FakeTimeoutExecutor(throwBelowSeconds: 0).run),
      save: save,
      deliverPaste: deliverPaste,
      readCaretContext: readCaretContext,
      englishWordOracle: englishWordOracle,
      resolveLanguage: resolveLanguage
        ?? {
          DictationLanguageResolver.resolve(
            lockedLanguage: $0, engineDetectsLanguage: $1, engineReportedLanguage: $2,
            text: $3, surroundingText: $4)
        },
      pasteCompletionRegistry: registry,
      currentTime: currentTime,
      telemetryState: telemetryState)
  }

  // MARK: Fallback metrics gate (#1624, widened #158)
  //
  // `KernelFinalizationWiring`'s real gate is `emitFallbackFields =
  // outcome.polishMetadata != nil || outcome.polishFallbackReason ==
  // "empty_output_floor" || outcome.llmProvider != nil` — drive it end to
  // end (store, THEN deliver, since deliver is what calls
  // updateTranscriptMetrics) rather than recomputing a simplified version of
  // the condition inside the test.

  @Test(
    "with no provider stamped at all, fallback reasons remain suppressed from metrics",
    .bug(
      "https://github.com/saurabhav88/EnviousWispr/issues/1624",
      "fallback metrics gate was recomputed inside its test"
    )
  )
  func unstampedFallbackReasonIsSuppressed() async throws {
    let outcome = KernelFinalizationOutcome()
    outcome.rawText = "original transcript text"
    outcome.polishMetadata = nil
    outcome.llmProvider = nil
    outcome.pipelineFellBackToRaw = true
    outcome.polishFallbackReason = "validator_discard"

    let wiring = makeWiring(outcome: outcome)
    try await wiring.store("original transcript text", UUID())
    _ = await wiring.deliver("original transcript text")

    let metrics = try #require(outcome.transcript?.metrics)
    #expect(metrics.polishFellBackToRaw == nil)
    #expect(metrics.polishFallbackReason == nil)
  }

  @Test(
    "issue #158: a successful non-AFM provider call whose output was rejected now emits honestly"
  )
  func claudeSuccessfulCallWithRejectedOutputEmitsFallback() async throws {
    // Models the real production shape a successful "all other providers"
    // polish call leaves behind (LLMPolishStep.swift's success path stamps
    // llmProvider unconditionally, for every provider, not just AFM) — the
    // validator rejected the polished output and fell back to raw.
    let outcome = KernelFinalizationOutcome()
    outcome.rawText = "original transcript text"
    outcome.polishMetadata = nil
    outcome.llmProvider = "claude"
    outcome.pipelineFellBackToRaw = true
    outcome.polishFallbackReason = "validator_discard"

    let wiring = makeWiring(outcome: outcome)
    try await wiring.store("original transcript text", UUID())
    _ = await wiring.deliver("original transcript text")

    let metrics = try #require(outcome.transcript?.metrics)
    #expect(metrics.polishFellBackToRaw == true)
    #expect(metrics.polishFallbackReason == "validator_discard")
  }

  @Test(
    "AFM metadata emits explicit false when polish did not fall back",
    .bug(
      "https://github.com/saurabhav88/EnviousWispr/issues/1624",
      "fallback metrics gate was recomputed inside its test"
    )
  )
  func successfulAFMEmitsFalseFallback() async throws {
    let outcome = KernelFinalizationOutcome()
    outcome.rawText = "original transcript text"
    outcome.polishedText = "Polished transcript text."
    outcome.polishMetadata = PolishMetadata(filterTripped: nil, filterFellBackToRaw: false)
    outcome.pipelineFellBackToRaw = false
    outcome.polishFallbackReason = nil

    let wiring = makeWiring(outcome: outcome)
    try await wiring.store("Polished transcript text.", UUID())
    _ = await wiring.deliver("Polished transcript text.")

    let metrics = try #require(outcome.transcript?.metrics)
    #expect(metrics.polishFilterTripped == nil)
    #expect(metrics.polishFellBackToRaw == false)
    #expect(metrics.polishFallbackReason == nil)
  }

  // MARK: - #1921 Chunk 2: the language/repair deadline handoff

  /// A resolution to hand the gate, distinct enough that its survival is visible.
  static let gateResolution = DictationLanguageResolver.Resolution(
    language: "en", source: .dictation, confidenceBucket: .ge90)

  @Test("#1921 The deadline gate's four phases, including the completed distinction")
  func deadlineGateFourPhaseMatrix() {
    // Obligation 10's third race order lives inside `withOrderedDeadline`, in the
    // gap between `await operation()` returning and `claim()` (`TaskTimeout.swift:123-125`).
    // No injected seam reaches it, and timing against the 100 ms boundary would be
    // a clock race. So that ordering is proven HERE, on the state machine itself,
    // and the production call site is verified structurally in the receipt.
    //
    // The `repair` versus `completed` distinction is the entire reason this gate
    // has four states rather than three: a three-state gate permanently disables a
    // word oracle that had already finished successfully.

    // Timeout while still resolving: nothing to report, nothing to disable.
    let resolving = LanguageRepairDeadlineGate()
    let fromResolving = resolving.timeOut()
    #expect(fromResolving.resolution == nil)
    #expect(fromResolving.shouldDisableOracle == false, "the oracle never ran")

    // Timeout while repair is running AND the oracle was genuinely consulted:
    // keep the resolution, disable.
    let running = LanguageRepairDeadlineGate()
    #expect(running.beginRepair(Self.gateResolution))
    #expect(running.authorizeOracleUse(), "an authorised repair may consult the oracle")
    let fromOracle = running.timeOut()
    #expect(fromOracle.resolution?.language == "en")
    #expect(fromOracle.resolution?.confidenceBucket == .ge90)
    #expect(fromOracle.shouldDisableOracle, "a genuinely stuck oracle must be disabled")

    // Timeout while repair is running but the oracle was NEVER touched.
    //
    // Integration review found this: `beginRepair` runs before
    // `CursorInsertionRepair.repair`, and repair has early exits and does its
    // spacing work before it ever consults the oracle. Arming on "repair began"
    // would permanently disable a healthy oracle that was never involved — the
    // exact harm this gate exists to prevent, moved one step later.
    //
    // Not reachable through the real wiring: the window is inside repair, and
    // forcing it would need either a production seam in `CursorInsertionRepair`
    // or a clock race. Proven here, on the state machine, like the completed
    // ordering above.
    let authorizedButUntouched = LanguageRepairDeadlineGate()
    #expect(authorizedButUntouched.beginRepair(Self.gateResolution))
    let fromUntouched = authorizedButUntouched.timeOut()
    #expect(
      fromUntouched.resolution?.language == "en",
      "the resolution still survives; only the disable decision differs")
    #expect(
      fromUntouched.shouldDisableOracle == false,
      "an oracle that was never consulted must not be punished for repair stalling")

    // Timeout after repair already returned: keep the resolution, do NOT disable.
    let completed = LanguageRepairDeadlineGate()
    #expect(completed.beginRepair(Self.gateResolution))
    #expect(completed.authorizeOracleUse())
    completed.completeRepair()
    let fromCompleted = completed.timeOut()
    #expect(fromCompleted.resolution?.language == "en", "a finished run keeps its answer")
    #expect(
      fromCompleted.shouldDisableOracle == false,
      "a healthy oracle that already finished must NOT be disabled")

    // A second timeout is inert.
    let repeated = completed.timeOut()
    #expect(repeated.resolution == nil)
    #expect(repeated.shouldDisableOracle == false)

    // Repair can never start once the timeout owns the phase.
    let lateStart = LanguageRepairDeadlineGate()
    _ = lateStart.timeOut()
    #expect(
      lateStart.beginRepair(Self.gateResolution) == false,
      "a resolver the deadline could not preempt must not enter repair")

    // And an un-preempted repair ALREADY INSIDE the deadline must not reach the
    // oracle once the timeout has claimed the phase.
    //
    // Integration review round 2 found this. Cancellation "cannot preempt a
    // blocked thread" (`TaskTimeout.swift:129`), so a repair authorised before
    // the deadline keeps running after it. Without this refusal it walks into
    // the real word oracle after the timeout gave up, making exactly the
    // unbounded blocking call the deadline exists to bound.
    let lateOracle = LanguageRepairDeadlineGate()
    #expect(lateOracle.beginRepair(Self.gateResolution))
    let lateTimeout = lateOracle.timeOut()
    #expect(
      lateTimeout.shouldDisableOracle == false,
      "it had not been consulted at the moment the deadline fired")
    #expect(
      lateOracle.authorizeOracleUse() == false,
      "and it must be refused entry afterwards, not merely recorded")

    // `completeRepair` from a phase that never began is inert, not a promotion.
    let neverBegan = LanguageRepairDeadlineGate()
    neverBegan.completeRepair()
    let afterInertComplete = neverBegan.timeOut()
    #expect(afterInertComplete.resolution == nil)
    #expect(afterInertComplete.shouldDisableOracle == false)
  }

  @Test("#1921 The language resolution reaches the real transcript metrics")
  func languageResolutionReachesTranscriptMetrics() async throws {
    // The first hop of the telemetry chain, exercised through the REAL
    // `updateTranscriptMetrics` rather than by constructing an `ExecutionMetrics`
    // in the test — which would prove only that I can copy two strings.
    //
    // `document` / `f70to90` are deliberately distinctive: neither is a default,
    // and neither is what any other path would produce, so a hop that silently
    // dropped the value could not pass by coincidence.
    let outcome = KernelFinalizationOutcome()
    let context = KernelSessionContext()
    context.config = .testDefault(autoPasteToActiveApp: true, smartInsertion: true)
    context.targetElement = Self.stubCaretElement()

    let wiring = makeWiring(
      outcome: outcome,
      context: context,
      readCaretContext: { _, _, _ in Self.midSentenceCaret },
      resolveLanguage: { _, _, _, _, _ in
        DictationLanguageResolver.Resolution(
          language: "de", source: .document, confidenceBucket: .f70to90)
      })

    let processed = try await wiring.processText("Review this before the meeting") {}
    try await wiring.store(processed, UUID())
    let delivery = await wiring.deliver(processed)

    #expect(delivery == .pasted, "the normal non-timeout route must still deliver")
    #expect(outcome.languageResolutionSource == "document")
    #expect(outcome.languageConfidenceBucket == "f70to90")

    let metrics = try #require(outcome.transcript?.metrics, "delivery must produce metrics")
    #expect(
      metrics.languageResolutionSource == "document",
      "the value must survive the outcome -> ExecutionMetrics hop unchanged")
    #expect(metrics.languageConfidenceBucket == "f70to90")
  }

  @Test("#1921 A stalled LANGUAGE stage times out without disabling the word oracle")
  func languageStageTimeoutLeavesOracleEnabled() async throws {
    // Race order one, through the REAL deadline. Before #1921 language
    // resolution ran outside it entirely, so this stall had no bound at all.
    //
    // A language stall must not latch an unrelated, healthy component off for
    // the rest of the process. A naive "did the oracle begin" flag gets this
    // right only by luck, because cancellation here cannot preempt the blocked
    // call.
    try await withEnglishWordOracleExclusion {
      EnglishWordOracleRuntime.resetForTesting()
      EnglishWordOracleRuntime.installForTesting(Self.testOracle)
      #expect(
        EnglishWordOracleRuntime.snapshot().isAvailable,
        "precondition: the oracle starts enabled, or this test cannot fail")

      let entered = DispatchSemaphore(value: 0)
      let release = DispatchSemaphore(value: 0)
      let exited = DispatchSemaphore(value: 0)
      // Records WHY the blocking wait ended. Without it, `exited` fires whether
      // the test released the blocker or the five-second fail-safe expired, so
      // the fallback could silently become the normal path.
      let releaseOutcome = OSAllocatedUnfairLock<DispatchTimeoutResult?>(initialState: nil)
      let outcome = KernelFinalizationOutcome()
      let context = KernelSessionContext()
      context.config = .testDefault(autoPasteToActiveApp: true, smartInsertion: true)
      context.targetElement = Self.stubCaretElement()
      let captured = CapturedRequest()

      let wiring = makeWiring(
        outcome: outcome,
        context: context,
        deliverPaste: { request in
          captured.request = request
          return Self.deliveredResult
        },
        readCaretContext: { _, _, _ in Self.midSentenceCaret },
        resolveLanguage: { _, _, _, _, _ in
          entered.signal()
          // deadline-fallback: `release` is the signal; this bound only stops a defect hanging the suite
          let waited = release.wait(timeout: .now() + 5)
          releaseOutcome.withLock { $0 = waited }
          exited.signal()
          return DictationLanguageResolver.Resolution(
            language: "en", source: .dictation, confidenceBucket: .ge90)
        })

      let delivery = Task { await wiring.deliver("Warmer and summer starts.") }

      // Prove the ordering this test is NAMED for. Without it the case passes
      // even if the resolver is never reached at all.
      #expect(await awaitSignal(entered), "the resolver must have been entered before the deadline")

      _ = await delivery.value

      // Cleanup BEFORE any throwing assertion, so a failure below cannot strand
      // a blocked thread for the rest of the suite.
      release.signal()
      #expect(await awaitSignal(exited), "the blocked resolver must have exited")
      #expect(
        releaseOutcome.withLock { $0 } == .success,
        "it must have exited because we released it, not because the fail-safe expired")

      let request = try #require(captured.request, "the paste route must have been reached")
      #expect(
        request.repairedText == nil,
        "a timed-out repair must offer no candidate, only today's payload")
      #expect(
        request.legacyText == "Warmer and summer starts. ",
        "and that payload must be exactly today's, trailing space included")
      #expect(
        outcome.languageResolutionSource == "none",
        "nothing was resolved in time, and the field must say so rather than guess")
      #expect(outcome.languageConfidenceBucket == "none")
      #expect(
        EnglishWordOracleRuntime.snapshot().isAvailable,
        "the oracle never ran, so the language stall must NOT have latched it off")
    }
  }

  @Test("#1921 A stalled ORACLE still latches, and the language answer survives")
  func oracleStageTimeoutLatchesAndKeepsResolution() async throws {
    // Race order two. Repair genuinely entered the oracle, so today's latching
    // must be preserved exactly — and the resolution the language stage already
    // produced must survive into telemetry rather than being reported as `none`,
    // which is what a gate without a payload would do.
    try await withEnglishWordOracleExclusion {
      EnglishWordOracleRuntime.resetForTesting()
      EnglishWordOracleRuntime.installForTesting(Self.testOracle)
      #expect(EnglishWordOracleRuntime.snapshot().isAvailable, "precondition")

      let entered = DispatchSemaphore(value: 0)
      let release = DispatchSemaphore(value: 0)
      let exited = DispatchSemaphore(value: 0)
      let releaseOutcome = OSAllocatedUnfairLock<DispatchTimeoutResult?>(initialState: nil)
      let blockingOracle = EnglishWordOracle(
        unavailableReason: nil,
        dictionaryVerdict: { _ in
          entered.signal()
          // deadline-fallback: `release` is the signal; this bound only stops a defect hanging the suite
          let waited = release.wait(timeout: .now() + 5)
          releaseOutcome.withLock { $0 = waited }
          exited.signal()
          return .ordinary
        },
        isLearnedWord: { _ in false },
        isRecognizedName: { _, _ in false })

      let outcome = KernelFinalizationOutcome()
      let context = KernelSessionContext()
      context.config = .testDefault(autoPasteToActiveApp: true, smartInsertion: true)
      context.targetElement = Self.stubCaretElement()
      let captured = CapturedRequest()

      let wiring = makeWiring(
        outcome: outcome,
        context: context,
        deliverPaste: { request in
          captured.request = request
          return Self.deliveredResult
        },
        readCaretContext: { _, _, _ in Self.midSentenceCaret },
        englishWordOracle: { blockingOracle },
        resolveLanguage: { _, _, _, _, _ in
          DictationLanguageResolver.Resolution(
            language: "en", source: .dictation, confidenceBucket: .ge90)
        })

      let delivery = Task { await wiring.deliver("Review this before the meeting") }

      #expect(
        await awaitSignal(entered),
        "repair must have genuinely reached the oracle, not merely timed out near it")

      _ = await delivery.value

      release.signal()
      #expect(await awaitSignal(exited), "the blocked oracle must have exited")
      #expect(
        releaseOutcome.withLock { $0 } == .success,
        "it must have exited because we released it, not because the fail-safe expired")

      let request = try #require(captured.request, "the paste route must have been reached")
      #expect(request.repairedText == nil, "a timed-out repair offers no candidate")
      #expect(
        request.legacyText == "Review this before the meeting ",
        "and the delivered payload must be exactly today's")
      #expect(
        EnglishWordOracleRuntime.snapshot().unavailableReason == .oracleTimedOut,
        "a genuinely stuck oracle must still be latched off, exactly as before #1921")
      #expect(
        outcome.languageResolutionSource == "dictation",
        "the language stage had already answered; the timeout must not erase it")
      #expect(outcome.languageConfidenceBucket == "ge90")
    }
  }

}

/// Hand-advanced logical clock for the tick-rate test. Local `@MainActor` copy:
/// the `ManualClock` in `LoadProgressWatcherTests` is `private` to that suite and
/// cannot be reused. Satisfies the `@MainActor () -> TimeInterval` clock seam.
@MainActor
private final class ManualClock {
  private(set) var now: TimeInterval = 0
  func advance(by seconds: TimeInterval) { now += seconds }
}

private enum WiringTestError: Error { case storage }

/// Awaits a `DispatchSemaphore` WITHOUT occupying the caller's actor.
///
/// The blocking side of these tests is a synchronous production closure, so a
/// semaphore is the only thing it can signal. But `DispatchSemaphore.wait` is
/// unavailable from an async context, and waiting on the `@MainActor` test body
/// would block the very actor `deliver` needs to make progress — a guaranteed
/// deadlock rather than a slow test.
///
/// So the wait happens on a global queue and the result comes back through a
/// continuation. The SIGNAL is the semaphore; the bound is a fail-safe so a
/// defect fails one case instead of hanging the suite.
private func awaitSignal(_ semaphore: DispatchSemaphore) async -> Bool {
  await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
    DispatchQueue.global().async {
      // deadline-fallback: the semaphore is the signal; this bound is the fail-safe
      continuation.resume(returning: semaphore.wait(timeout: .now() + 5) == .success)
    }
  }
}

/// Captures the real delivery request so a timeout test can assert on the
/// payload that ACTUALLY reached the paste route, rather than on the outcome
/// fields alone. `@MainActor` because `deliverPaste` is.
@MainActor
private final class CapturedRequest {
  var request: PasteDeliveryRequest?
}

/// Deterministic polisher for the #1022 short-dictation test: enables the
/// polish step (provider set, connector mocked) so the persisted nil can only
/// come from the too-short gate. If the gate ever let the short input through,
/// the test would see "canned polish output" persisted instead of nil.
private struct CannedPolisher: TranscriptPolisher {
  func polish(
    text: String,
    instructions: PolishInstructions,
    config: LLMProviderConfig,
    onToken: (@Sendable (String) -> Void)?
  ) async throws -> LLMResult {
    LLMResult(polishedText: "canned polish output")
  }
}

@MainActor
private final class SignalFlag {
  var fired = false
}

@MainActor
private final class SaveCountBox {
  var count = 0
  var last: Transcript?
}

@MainActor
private final class DeliveredPayloadBox {
  var payloads: [String] = []
}

@MainActor
private final class RestoreFlagBox {
  var value: Bool?
}

/// The whole delivery request, not just its text. Chunk 6 transports three
/// things now, so a box that keeps only the payload cannot see the other two.
@MainActor
private final class DeliveryRequestBox {
  var requests: [PasteDeliveryRequest] = []
}

/// Cancels mid-polish. The runner absorbs this silently rather than surfacing
/// it, so the heart path continues with the pre-step text.
private struct CancellingPolisher: TranscriptPolisher {
  func polish(
    text: String,
    instructions: PolishInstructions,
    config: LLMProviderConfig,
    onToken: (@Sendable (String) -> Void)?
  ) async throws -> LLMResult {
    throw CancellationError()
  }
}

/// Fails every polish, so the chain surfaces the error and the heart path
/// still delivers the raw words.
private struct ThrowingPolisher: TranscriptPolisher {
  func polish(
    text: String,
    instructions: PolishInstructions,
    config: LLMProviderConfig,
    onToken: (@Sendable (String) -> Void)?
  ) async throws -> LLMResult {
    throw WiringTestError.storage
  }
}

@MainActor
private final class SavedTranscriptBox {
  var transcript: Transcript?
}
