import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprPipeline

/// #3438 chunk 4. A take's AI polish setup is frozen when the take starts, carried through the
/// real finalization step, and handed back once after the take concludes. When this fails, a
/// card or warning is raised by another take, by a stale setup, twice, or never.
@MainActor
@Suite(
  "A take's polish outcome is frozen, carried and handed back once (#3438)", .tags(.productOutcome))
struct PolishTakeOutcomeCarryTests {

  @MainActor
  final class HookLog {
    var freezes = 0
    var frozen: PolishSetupTakeContext?
    var classified: [(PolishSetupEvidence, PolishSetupTakeContext)] = []
    var answer: PolishSetupProblemTag?
    var recorded: [(String, PolishSetupProblemTag)] = []
    var ingested: [PolishTakeOutcome] = []

    var hooks: PolishSetupTakeHooks {
      PolishSetupTakeHooks(
        freeze: {
          self.freezes += 1
          return self.frozen
        },
        classify: {
          self.classified.append(($0, $1))
          return self.answer
        },
        recordTerminalProblem: { self.recorded.append(($0, $1)) },
        ingest: { self.ingested.append($0) })
    }
  }

  private static func steps(
    polish: LLMPolishStep = LLMPolishStep(keychainManager: KeychainManager())
  )
    -> LimbSteps
  {
    LimbSteps(
      snippetExpansion: SnippetExpansionStep(),
      wordCorrection: WordCorrectionStep(),
      learnedWordCheck: LearnedWordCheckStep(),
      fillerRemoval: FillerRemovalStep(),
      emojiFormatter: EmojiFormatterStep(),
      inverseTextNormalization: InverseTextNormalizationStep(),
      englishSpelling: EnglishSpellingStep(target: .text),
      llmPolish: polish,
      englishSpellingAfterPolish: EnglishSpellingStep(target: .polishedText),
      emojiRestore: EmojiRestoreStep())
  }

  private struct Driver {
    let driver: KernelDictationDriver
    let context: KernelSessionContext
  }

  private static func driver() -> Driver {
    let context = KernelSessionContext()
    let adapter = FakeEngine(behavior: .batchSuccess(text: "x"), clock: FakeClock())
    let kernel = RecordingSessionKernel(
      adapter: adapter, audioCapture: FakeAudioCapture(), vad: FakeVADSignalSource(),
      currentTick: { 0 }, sleepTicks: { _ in },
      processText: { raw, _ in raw },
      store: { _, _, _ in }, deliver: { _, _ in .pasted },
      engineMutationScope: .alwaysAllowedForTesting, minimumRecordingTicks: 0)
    let observer = KernelHeartPathTelemetryObserver(
      kernel: kernel, audioCapture: FakeAudioCapture(),
      emitter: HeartPathTelemetryEmitter(
        backend: .parakeet, captureTelemetry: CaptureTelemetryState()),
      emitLifecycleEvent: { _ in })
    let driver = KernelDictationDriver(
      kernel: kernel, observer: observer, outcome: KernelFinalizationOutcome(),
      context: context, steps: steps(), adapter: adapter,
      engineMutationScope: .alwaysAllowedForTesting)
    driver.start()
    return Driver(driver: driver, context: context)
  }

  private static let openAITake = PolishSetupTakeContext(
    provider: .openAI, model: "gpt-4o-mini", configurationRevision: 4, episode: 2)

  // MARK: - Frozen at the take's start

  @Test("the start freezes the setup beside the config, only when it names the same model")
  func freezesAtStart() async throws {
    let matching = Self.driver()
    let log = HookLog()
    log.frozen = Self.openAITake
    matching.driver.polishSetupHooks = log.hooks
    try await matching.driver.handle(
      event: .toggleRecording(.testDefault(llmProvider: .openAI, llmModel: "gpt-4o-mini")))
    #expect(log.freezes == 1)
    #expect(matching.context.polishSetupContext == Self.openAITake)
    #expect(matching.context.polishSetupHooks != nil)

    // The setup moved between the config and the freeze: freeze nothing rather than lie.
    let moved = Self.driver()
    let movedLog = HookLog()
    movedLog.frozen = Self.openAITake
    moved.driver.polishSetupHooks = movedLog.hooks
    try await moved.driver.handle(
      event: .toggleRecording(.testDefault(llmProvider: .openAI, llmModel: "gpt-5-mini")))
    #expect(moved.context.polishSetupContext == nil)

    // No warning owner wired: nothing is frozen.
    let unwired = Self.driver()
    try await unwired.driver.handle(
      event: .toggleRecording(.testDefault(llmProvider: .openAI, llmModel: "gpt-4o-mini")))
    #expect(unwired.context.polishSetupContext == nil)
  }

  // MARK: - Carried through the real finalization step

  private struct MissingKeyPolisher: TranscriptPolisher {
    func polish(
      text: String, instructions: PolishInstructions, config: LLMProviderConfig,
      onToken: (@Sendable (String) -> Void)?
    ) async throws -> LLMResult {
      throw LLMError.classified(.apiKeyMissing)
    }
  }

  private static func wiring(
    _ outcome: KernelFinalizationOutcome, context: KernelSessionContext, takeID: String
  ) -> KernelFinalizationWiring {
    let polish = LLMPolishStep(keychainManager: KeychainManager())
    polish.llmProvider = .openAI
    polish.llmModel = "gpt-4o-mini"
    polish.makePolisher = { _, _, _ in MissingKeyPolisher() }
    let telemetry = KernelTelemetryState()
    telemetry.resetForNewSession(takeID: takeID, polishEnabled: true)
    return KernelFinalizationWiring(
      outcome: outcome, context: context,
      adapter: FakeEngine(behavior: .batchSuccess(text: "hi"), clock: FakeClock()),
      steps: steps(polish: polish),
      textProcessingRunner: TextProcessingRunner(
        timeoutExecutor: FakeTimeoutExecutor(throwBelowSeconds: 0.0).run),
      save: { _, _ in },
      deliverPaste: { _ in
        PasteDeliveryResult(
          tier: .cgEvent, durationMs: 1, outcome: .delivered(tier: .cgEvent, durationMs: 1))
      },
      pasteCompletionRegistry: nil, telemetryState: telemetry, copyToClipboard: { _ in })
  }

  private let raw = "so the invoice is still open I think and I was going to send it today"

  @Test("the finalization step classifies under the frozen setup and keeps the take's own ID")
  func carriedThroughFinalization() async throws {
    let log = HookLog()
    log.answer = .cloudKeyMissing
    let context = KernelSessionContext()
    context.config = .testDefault(llmProvider: .openAI, llmModel: "gpt-4o-mini")
    context.polishSetupContext = Self.openAITake
    context.polishSetupHooks = log.hooks
    let outcome = KernelFinalizationOutcome()
    let text = try await Self.wiring(outcome, context: context, takeID: "take-live")
      .processText(raw) {}

    let polish = try #require(outcome.polishTakeOutcome)
    #expect(polish.takeID == "take-live")
    #expect(polish.context == Self.openAITake)
    #expect(polish.evidence == .cloudKeyMissing)
    #expect(polish.setupProblem == .cloudKeyMissing)
    #expect(log.classified.count == 1)
    #expect(log.classified.first?.1 == Self.openAITake, "judged for the FROZEN setup")
    #expect(log.recorded.count == 1)
    #expect(log.recorded.first?.0 == "take-live")
    // The text that ships and the notice are today's.
    #expect(text.isEmpty == false)
    #expect(outcome.polishNotice?.leadIn == .skipped)
  }

  @Test("no frozen setup or no hooks: nothing is classified, recorded or carried")
  func nothingWithoutAFrozenSetup() async throws {
    let log = HookLog()
    log.answer = .cloudKeyMissing
    let context = KernelSessionContext()
    context.config = .testDefault(llmProvider: .openAI, llmModel: "gpt-4o-mini")
    context.polishSetupHooks = log.hooks
    let outcome = KernelFinalizationOutcome()
    _ = try await Self.wiring(outcome, context: context, takeID: "take-live").processText(raw) {}
    #expect(outcome.polishTakeOutcome == nil)
    #expect(log.classified.isEmpty)
    #expect(log.recorded.isEmpty)
    #expect(
      KernelFinalizationWiring.polishSetupProbe(
        takeID: nil, context: Self.openAITake, hooks: log.hooks) == nil)
  }

  // MARK: - Handed back once, for the concluded take only

  private static func outcome(_ takeID: String) -> PolishTakeOutcome {
    PolishTakeOutcome(
      takeID: takeID, context: openAITake, result: .skippedWithNotice,
      evidence: .cloudKeyMissing, setupProblem: .cloudKeyMissing, observedAt: .now)
  }

  @Test("only the concluded take's own outcome is handed back, and only once")
  func handedBackOnce() {
    let a = Self.outcome("take-A")
    // Not concluded yet, or another take concluded: nothing.
    #expect(
      KernelDictationDriver.deliverablePolishOutcome(
        a, concludedTakeID: nil, alreadyDelivered: nil) == nil)
    #expect(
      KernelDictationDriver.deliverablePolishOutcome(
        a, concludedTakeID: "take-B", alreadyDelivered: nil) == nil)
    // Concluded: handed back.
    #expect(
      KernelDictationDriver.deliverablePolishOutcome(
        a, concludedTakeID: "take-A", alreadyDelivered: nil) == a)
    // A second state notification for the same take: nothing.
    #expect(
      KernelDictationDriver.deliverablePolishOutcome(
        a, concludedTakeID: "take-A", alreadyDelivered: "take-A") == nil)
    // The next take, after the previous one was delivered: handed back.
    let b = Self.outcome("take-B")
    #expect(
      KernelDictationDriver.deliverablePolishOutcome(
        b, concludedTakeID: "take-B", alreadyDelivered: "take-A") == b)
  }

  @Test("a real take hands its own outcome back once after it concludes, and never to the next take")
  func realTakeHandsBackOnce() async throws {
    let clock = FakeClock()
    let engine = FakeEngine(behavior: .batchSuccess(text: "hello"), clock: clock)
    let capture = FakeAudioCapture()
    let wrapper = KernelRecordingSession(
      engine: engine, capture: capture, vad: FakeVADSignalSource(), clock: clock,
      paste: FakePasteTarget())
    let outcome = KernelFinalizationOutcome()
    let observer = KernelHeartPathTelemetryObserver(
      kernel: wrapper.testKernel, audioCapture: capture,
      emitter: HeartPathTelemetryEmitter(
        backend: .parakeet, captureTelemetry: CaptureTelemetryState()),
      emitLifecycleEvent: { _ in })
    let driver = KernelDictationDriver(
      kernel: wrapper.testKernel, observer: observer, outcome: outcome,
      context: KernelSessionContext(), steps: Self.steps(), adapter: engine,
      engineMutationScope: .alwaysAllowedForTesting)
    let log = HookLog()
    driver.polishSetupHooks = log.hooks
    driver.start()

    // Take A starts; its finalization step writes A's outcome.
    await wrapper.apply(.start)
    capture.deliverBuffer()
    await wrapper.drainReadyWork()
    let takeA = try #require(wrapper.telemetryState.takeID)
    outcome.polishTakeOutcome = Self.outcome(takeA)
    // Still in flight: nothing is handed back.
    driver.deliverPolishTakeOutcome()
    #expect(log.ingested.isEmpty)

    await wrapper.apply(.stop)
    await wrapper.drainUntilConcluded()
    #expect(driver.lastTakeID == takeA)
    // Repeated state notifications: once.
    driver.deliverPolishTakeOutcome()
    driver.deliverPolishTakeOutcome()
    #expect(log.ingested.map(\.takeID) == [takeA])

    // Take B concludes with A's outcome still in the slot: B gets nothing of A's.
    await wrapper.apply(.start)
    capture.deliverBuffer()
    await wrapper.drainReadyWork()
    let takeB = try #require(wrapper.telemetryState.takeID)
    #expect(takeB != takeA)
    await wrapper.apply(.stop)
    await wrapper.drainUntilConcluded()
    #expect(driver.lastTakeID == takeB)
    driver.deliverPolishTakeOutcome()
    #expect(log.ingested.map(\.takeID) == [takeA])
  }
}
