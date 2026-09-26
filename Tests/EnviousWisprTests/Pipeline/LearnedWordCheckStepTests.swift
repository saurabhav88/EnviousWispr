import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// #3105: the learned-word check changes only what an installed checker
/// approves, and leaves the text exactly as it arrived on every failure.
@Suite("Learned word check step (#3105)", .tags(.productOutcome))
@MainActor
struct LearnedWordCheckStepTests {
  private struct Checker: LearnedWordChecking {
    enum Mode {
      case approveWord(String)
      case approveNone, fail, dropOne, cancelled, hangIgnoringCancellation
    }
    let mode: Mode
    var armName: String { "fake" }
    var scoresAreComparable: Bool { false }
    struct Failure: Error {}
    func decide(_ questions: [LearnedWordCheckQuestion]) async throws -> [LearnedWordCheckDecision]
    {
      switch mode {
      case .fail: throw Failure()
      case .cancelled: throw CancellationError()
      case .hangIgnoringCancellation:
        // Busy-waits two seconds and ignores cancellation, like a wedged model call.
        let end = Date().addingTimeInterval(2)
        while Date() < end { await Task.yield() }
        return questions.map { .init(questionID: $0.id, approved: true) }
      case .approveNone: return questions.map { .init(questionID: $0.id, approved: false) }
      case .dropOne: return questions.dropFirst().map { .init(questionID: $0.id, approved: true) }
      case .approveWord(let spot):
        return questions.map {
          .init(questionID: $0.id, approved: String($0.sentence[$0.range]) == spot)
        }
      }
    }
  }

  private let tuist = CustomWord(
    canonical: "Tuist", aliases: ["toast"], learnedAliases: ["toast"],
    learnedAt: Date(timeIntervalSince1970: 1_790_000_000))
  private let twin = "The plot twist surprised me more than the day toast regenerated my project."

  private func step(_ mode: Checker.Mode?, words: [CustomWord]? = nil) -> LearnedWordCheckStep {
    let step = LearnedWordCheckStep()
    step.correctorVocabulary = CorrectorVocabulary(terms: words ?? [tuist], generation: 1)
    step.checker = mode.map { Checker(mode: $0) }
    step.wordCorrectionEnabled = true
    return step
  }

  private func run(_ step: LearnedWordCheckStep, _ text: String) async throws -> String {
    try await step.process(TextProcessingContext(text: text, language: "en")).text
  }

  @Test("no checker installed: the step records why and changes nothing")
  func noCheckerIsOff() async throws {
    let s = step(nil)
    #expect(s.isEnabled)
    #expect(try await run(s, twin) == twin)
    #expect(s.lastOutcome?.fallbackReason == .noChecker)
  }

  @Test("a frozen ready choice survives a later provider change")
  func frozenReadyChoice() async throws {
    let s = step(nil)
    var context = TextProcessingContext(text: twin, language: "en")
    context.frozenLearnedWordChecker = LearnedWordCheckerSelection(
      checker: Checker(mode: .approveWord("toast")), identity: "test_ready")
    #expect(try await s.process(context).text.contains("day Tuist regenerated"))
  }

  @Test("a frozen absent choice stays absent after a checker appears")
  func frozenAbsentChoiceAndFacts() async throws {
    let s = step(.approveWord("toast"))
    var recorded: [LearnedCheckTerminalFacts] = []
    s.recordTerminalFacts = { _, facts in recorded.append(facts) }
    var context = TextProcessingContext(text: twin, language: "en")
    context.takeID = "take-absent"
    context.frozenLearnedWordChecker = .init(absence: .adapterDownloading)
    #expect(try await s.process(context).text == twin)
    #expect(recorded.count == 1)
    #expect(recorded.first?.fallbackReason == "no_checker")
    #expect(recorded.first?.checkerStatus == "no_checker")
    #expect(recorded.first?.absenceReason == "adapter_downloading")
  }

  @Test("the absence vocabulary is closed and content-free")
  func absenceCodes() {
    let values: [(LearnedWordCheckerAbsence, String)] = [
      (.notEGOne, "not_eg_one"), (.baseNotAdmitted, "base_not_admitted"),
      (.adapterDownloading, "adapter_downloading"),
      (.adapterDeliveryFailed, "adapter_delivery_failed"),
      (.deliveryDisabled, "delivery_disabled"),
      (.baseMismatch("family"), "base_mismatch_family"),
      (.baseMismatch("revision"), "base_mismatch_revision"),
      (.baseMismatch("variant"), "base_mismatch_variant"),
      (.baseMismatch("shard_hash"), "base_mismatch_shard_hash"),
      (.baseMismatch("prompt_template"), "base_mismatch_prompt_template"),
      (.baseMismatch("runtime"), "base_mismatch_runtime"),
      (.serverWithoutAdapter("adapter_missing"), "server_without_adapter_adapter_missing"),
      (
        .serverWithoutAdapter("adapter_server_exited"),
        "server_without_adapter_adapter_server_exited"
      ),
      (
        .serverWithoutAdapter("adapter_server_never_ready"),
        "server_without_adapter_adapter_server_never_ready"
      ),
      (.serverUnavailable, "server_unavailable"),
      (.selectionTimedOut, "selection_timed_out"),
    ]
    for (absence, expected) in values { #expect(absence.code == expected) }
  }

  @Test("only the approved spot changes; the everyday twin stays")
  func approvedSpotOnly() async throws {
    let s = step(.approveWord("toast"))
    #expect(s.isEnabled)
    #expect(
      try await run(s, twin)
        == "The plot twist surprised me more than the day Tuist regenerated my project.")
    #expect(s.lastOutcome?.applied == 1 && s.lastOutcome?.fallbackReason == nil)
  }

  @Test("a checker that rejects everything changes nothing")
  func rejectAll() async throws {
    let s = step(.approveNone)
    #expect(try await run(s, twin) == twin)
    #expect(s.lastOutcome?.applied == 0 && (s.lastOutcome?.flagged ?? 0) >= 1)
  }

  @Test("a checker error leaves the text unchanged and says why")
  func checkerError() async throws {
    let s = step(.fail)
    #expect(try await run(s, twin) == twin)
    #expect(s.lastOutcome?.fallbackReason == .checkerError)
  }

  @Test("an answer missing a decision is not trusted at all")
  func malformedAnswer() async throws {
    let s = step(.dropOne)
    #expect(try await run(s, twin) == twin)
    #expect(s.lastOutcome?.fallbackReason == .malformedAnswer)
  }

  @Test("a vocabulary with no learned word keeps the step off")
  func noLearnedWords() async throws {
    let s = step(.approveWord("toast"), words: [CustomWord(canonical: "Tuist", aliases: ["toast"])])
    #expect(s.isEnabled == false)
  }

  @Test("the take's frozen vocabulary wins over a later broadcast")
  func frozenVocabularyWins() async throws {
    let s = step(.approveWord("toast"), words: [])
    var context = TextProcessingContext(text: twin, language: "en")
    context.frozenCorrectorVocabulary = CorrectorVocabulary(terms: [tuist], generation: 7)
    #expect(
      try await s.process(context).text
        == "The plot twist surprised me more than the day Tuist regenerated my project.")
  }

  @Test("the take's counts reach its terminal facts; no take id records nothing")
  func terminalFactsPerTake() async throws {
    let s = step(.approveWord("toast"))
    var recorded: [(String, LearnedCheckTerminalFacts)] = []
    s.recordTerminalFacts = { recorded.append(($0, $1)) }
    var context = TextProcessingContext(text: twin, language: "en")
    context.takeID = "take-1"
    _ = try await s.process(context)
    #expect(recorded.count == 1 && recorded.first?.0 == "take-1")
    #expect(recorded.first?.1.applied == 1 && recorded.first?.1.arm == "fake")
    #expect(recorded.first?.1.fallbackReason == nil)
    _ = try await s.process(TextProcessingContext(text: twin, language: "en"))
    #expect(recorded.count == 1, "recovery and file import have no take and record nothing")
  }

  @Test("a checker cancelled by the step cap is reported as a deadline, text unchanged")
  func deadlineIsItsOwnReason() async throws {
    let s = step(.cancelled)
    #expect(try await run(s, twin) == twin)
    #expect(s.lastOutcome?.fallbackReason == .deadline)
  }

  @Test("Dictionary off: the step is off even with a checker installed")
  func dictionaryOffDisablesTheStep() async throws {
    let s = step(.approveWord("toast"))
    s.wordCorrectionEnabled = false
    #expect(s.isEnabled == false)
  }

  @Test("a checker that ignores cancellation cannot hold the take past the step's deadline")
  func deadlineDoesNotWaitForTheChecker() async throws {
    let s = step(.hangIgnoringCancellation)
    s.answerDeadline = .milliseconds(100)
    let start = ContinuousClock.now
    #expect(try await run(s, twin) == twin)
    #expect(ContinuousClock.now - start < .milliseconds(1000))
    #expect(s.lastOutcome?.fallbackReason == .deadline)
  }

  @Test("a selection that never answers cannot hold the take; a prompt one is kept")
  func selectionIsBounded() async {
    final class Gate: @unchecked Sendable {
      var parked: CheckedContinuation<Void, Never>?
    }
    let gate = Gate()
    let s = step(nil)
    s.selectionDeadline = .milliseconds(100)
    s.selectionProvider = { _, _ in
      await withCheckedContinuation { gate.parked = $0 }
      return LearnedWordCheckerSelection(absence: .notEGOne)
    }
    let start = ContinuousClock.now
    let stalled = await s.boundedSelection(for: .egOne, language: "en")
    #expect(stalled?.absence == .selectionTimedOut)
    #expect(ContinuousClock.now - start < .milliseconds(1000))
    gate.parked?.resume()

    s.selectionProvider = { _, _ in LearnedWordCheckerSelection(absence: .serverUnavailable) }
    #expect(await s.boundedSelection(for: .egOne, language: "de")?.absence == .serverUnavailable)
    s.selectionProvider = nil
    #expect(await s.boundedSelection(for: .egOne, language: "en") == nil)
  }
}
