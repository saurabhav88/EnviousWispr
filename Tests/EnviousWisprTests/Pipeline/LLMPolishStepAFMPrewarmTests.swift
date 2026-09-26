import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// #3195 PR B: the Apple session prepared at key-up belongs to one take and is used at
/// most once. When these fail, a dictation can be polished with a session prepared for a
/// different take, twice, or by a file import.
@MainActor
@Suite("LLMPolishStep key-up prepared Apple session slot (#3195)", .tags(.productOutcome))
struct LLMPolishStepAFMPrewarmTests {

  /// Lets a test hold a preparation open and release it on cue, without sleeps.
  actor Gate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
      if released { return }
      await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
      released = true
      waiters.forEach { $0.resume() }
      waiters = []
    }
  }

  final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
  }

  final class TextBox: @unchecked Sendable { var text: String? }

  struct RecordingPolisher: TranscriptPolisher {
    let box: TextBox
    func polish(
      text: String, instructions: PolishInstructions, config: LLMProviderConfig,
      onToken: (@Sendable (String) -> Void)?
    ) async throws -> LLMResult {
      box.text = text
      return LLMResult(polishedText: text)
    }
  }

  private let transcript = "so i was thinking we could maybe ship the new thing some time next week"

  private func appleStep(preparer: @escaping LLMPolishStep.AFMSessionPreparer) -> LLMPolishStep {
    let step = LLMPolishStep(keychainManager: KeychainManager())
    step.llmProvider = .appleIntelligence
    step.llmModel = "apple-intelligence"
    step.prepareAFMSession = preparer
    return step
  }

  private func filled(_ step: LLMPolishStep, take: String, carrier: String = "carrier") async {
    step.prepareAFMSession = { _ in carrier }
    step.beginAFMPrewarm(takeID: take, expectedDetectedLanguage: nil)
    await step.afmPrewarmTask?.value
  }

  @Test("the exact take claims its prepared session once")
  func exactTakeClaimsOnce() async {
    let step = appleStep { _ in "unused" }
    await filled(step, take: "take-1")
    #expect(step.claimAFMPrewarm(takeID: "take-1") as? String == "carrier")
    #expect(step.claimAFMPrewarm(takeID: "take-1") == nil, "single use")
  }

  @Test("another take cannot claim it and leaves it for its own take")
  func wrongTakeLeavesTheSlot() async {
    let step = appleStep { _ in "unused" }
    await filled(step, take: "take-1")
    #expect(step.claimAFMPrewarm(takeID: "take-2") == nil)
    #expect(step.claimAFMPrewarm(takeID: "take-1") as? String == "carrier")
  }

  @Test("a file import (no take id) neither claims nor clears the live take's session")
  func fileImportLeavesTheSlot() async throws {
    let step = appleStep { _ in "unused" }
    await filled(step, take: "take-1")
    let box = TextBox()
    step.makePolisher = { _, _, _ in RecordingPolisher(box: box) }
    let out = try await step.process(TextProcessingContext(text: transcript, language: "en"))
    #expect(box.text == transcript)
    #expect(out.afmPrewarmOutcome == nil)
    #expect(step.claimAFMPrewarm(takeID: "take-1") as? String == "carrier")
  }

  @Test("the live take's process() consumes the slot even through an injected polisher")
  func processConsumesTheSlot() async throws {
    let step = appleStep { _ in "unused" }
    await filled(step, take: "take-1")
    let box = TextBox()
    step.makePolisher = { _, _, _ in RecordingPolisher(box: box) }
    var context = TextProcessingContext(text: transcript, language: "en")
    context.takeID = "take-1"
    let out = try await step.process(context)
    #expect(box.text == transcript)
    #expect(out.afmPrewarmOutcome == nil, "a non-Apple polisher reports no prewarm outcome")
    #expect(step.claimAFMPrewarm(takeID: "take-1") == nil, "consumed by process()")
  }

  @Test("a separately built step (recovery) sees no slot")
  func separateStepSeesNothing() async {
    let live = appleStep { _ in "unused" }
    await filled(live, take: "take-1")
    let recovery = appleStep { _ in "unused" }
    #expect(recovery.claimAFMPrewarm(takeID: "take-1") == nil)
    #expect(live.claimAFMPrewarm(takeID: "take-1") as? String == "carrier")
  }

  @Test("no preparation starts unless Apple Intelligence is the provider")
  func nonAppleProviderPreparesNothing() async {
    let calls = Counter()
    let step = LLMPolishStep(keychainManager: KeychainManager())
    step.llmProvider = .openAI
    step.prepareAFMSession = { _ in
      calls.increment()
      return "carrier"
    }
    step.beginAFMPrewarm(takeID: "take-1", expectedDetectedLanguage: nil)
    await step.afmPrewarmTask?.value
    #expect(step.afmPrewarmTask == nil)
    #expect(calls.count == 0)
    #expect(step.claimAFMPrewarm(takeID: "take-1") == nil)
  }

  @Test("the expected language reaches the preparer")
  func expectedLanguageIsPassed() async {
    final class LangBox: @unchecked Sendable { var lang: String?? = .none }
    let seen = LangBox()
    let step = appleStep { lang in
      seen.lang = .some(lang)
      return "carrier"
    }
    step.beginAFMPrewarm(takeID: "take-1", expectedDetectedLanguage: "de")
    await step.afmPrewarmTask?.value
    #expect(seen.lang == .some("de"))
  }

  @Test(
    "a claim while preparation is still running gets nothing, and the late result is never installed"
  )
  func pendingPreparationIsNotWaitedFor() async {
    let gate = Gate()
    let step = appleStep { _ in
      await gate.wait()
      return "late"
    }
    step.beginAFMPrewarm(takeID: "take-1", expectedDetectedLanguage: nil)
    let pending = step.afmPrewarmTask
    #expect(pending != nil)
    #expect(step.claimAFMPrewarm(takeID: "take-1") == nil, "polish does not wait")
    await gate.release()
    await pending?.value
    #expect(step.claimAFMPrewarm(takeID: "take-1") == nil, "late completion not installed")
  }

  @Test("clearing an old take never clears a newer one; clearing all does")
  func clearIsTakeScoped() async {
    let step = appleStep { _ in "unused" }
    await filled(step, take: "take-2")
    step.clearAFMPrewarm(for: "take-1")
    #expect(step.claimAFMPrewarm(takeID: "take-2") as? String == "carrier")
    await filled(step, take: "take-3")
    step.clearAFMPrewarm()
    #expect(step.claimAFMPrewarm(takeID: "take-3") == nil)
  }

  @Test("a new take's preparation replaces the old one, whose late result is dropped")
  func newTakeReplacesOld() async {
    let gate = Gate()
    let step = appleStep { _ in
      await gate.wait()
      return "old"
    }
    step.beginAFMPrewarm(takeID: "take-1", expectedDetectedLanguage: nil)
    let old = step.afmPrewarmTask
    await filled(step, take: "take-2", carrier: "new")
    await gate.release()
    await old?.value
    #expect(step.claimAFMPrewarm(takeID: "take-1") == nil)
    #expect(step.claimAFMPrewarm(takeID: "take-2") as? String == "new")
  }
}
