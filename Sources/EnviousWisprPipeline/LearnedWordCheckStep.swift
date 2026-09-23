import EnviousWisprCore
import EnviousWisprPostProcessing
import EnviousWisprServices
import Foundation

public enum LearnedWordCheckerAbsence: Sendable, Equatable {
  case notEGOne, baseNotAdmitted, adapterDownloading, adapterDeliveryFailed, deliveryDisabled
  case baseMismatch(String), unqualifiedLanguage, serverWithoutAdapter(String), serverUnavailable

  public var code: String {
    switch self {
    case .notEGOne: "not_eg_one"
    case .baseNotAdmitted: "base_not_admitted"
    case .adapterDownloading: "adapter_downloading"
    case .adapterDeliveryFailed: "adapter_delivery_failed"
    case .deliveryDisabled: "delivery_disabled"
    case .baseMismatch(let reason): "base_mismatch_\(reason)"
    case .unqualifiedLanguage: "unqualified_language"
    case .serverWithoutAdapter(let reason): "server_without_adapter_\(reason)"
    case .serverUnavailable: "server_unavailable"
    }
  }
}

/// The judge that owns the selected polish engine's learned-word check, named
/// for the Dictionary status line. Each judge's owner fills it, so a new judge
/// or a newly qualified language needs no edit to the copy.
public struct LearnedWordJudge: Sendable, Equatable {
  public let displayName: String
  /// Lowercase language codes the judge revision is qualified for.
  public let qualifiedLanguages: [String]

  public init(displayName: String, qualifiedLanguages: [String]) {
    self.displayName = displayName
    self.qualifiedLanguages = qualifiedLanguages
  }
}

public struct LearnedWordCheckerSelection: Sendable {
  public let checker: (any LearnedWordChecking)?
  public let identity: String?
  public let absence: LearnedWordCheckerAbsence?
  /// Only a failed or cancelled fetch on a configured source offers a retry.
  public let retryAvailable: Bool
  /// Nil when the selected engine has no judge (`notEGOne`) or in tests.
  public let judge: LearnedWordJudge?

  public init(checker: any LearnedWordChecking, identity: String, judge: LearnedWordJudge? = nil) {
    self.checker = checker
    self.identity = identity
    absence = nil
    retryAvailable = false
    self.judge = judge
  }

  public init(
    absence: LearnedWordCheckerAbsence, retryAvailable: Bool = false, judge: LearnedWordJudge? = nil
  ) {
    checker = nil
    identity = nil
    self.absence = absence
    self.retryAvailable = retryAvailable
    self.judge = judge
  }

  public func naming(_ judge: LearnedWordJudge) -> LearnedWordCheckerSelection {
    if let checker, let identity {
      return .init(checker: checker, identity: identity, judge: judge)
    }
    return .init(
      absence: absence ?? .serverUnavailable, retryAvailable: retryAvailable, judge: judge)
  }
}

/// #3105: the ONLY place an automatically learned word may change dictated text.
///
/// Runs right after `WordCorrectionStep`, which no longer swaps learned claims
/// (`WordCorrector.TriggerOwner.checkerOnly`). Candidates are the spots that
/// sound like a learned word plus exact occurrences of its observed
/// misspellings (`LearnedWordCandidates`); each becomes one A/B question for
/// the installed checker, and only approved spots change
/// (`LearnedWordSpanApplier`).
///
/// A limb, never the heart path: with no qualified checker the step is off;
/// a checker that throws, answers late (the runner's `maxDuration`) or
/// returns malformed decisions leaves the text exactly as it arrived, with a
/// closed `fallbackReason`. Plan:
/// docs/feature-requests/issue-3105-2026-09-23-auto-dictionary.md §3.1-3.3.
@MainActor
public final class LearnedWordCheckStep: TextProcessingStep, CorrectorVocabularyConsumer {
  public let name = "Learned Word Check"

  /// The corrector lane. Read as a snapshot at the start of `process`; the
  /// finalization wiring freezes one value per take for both this step and
  /// Word Correction (plan §3.1 step 1).
  public var correctorVocabulary: CorrectorVocabulary = .empty

  /// The qualified checker for direct callers, or nil. Nil leaves text alone
  /// and records no_checker when the vocabulary contains learned words.
  public var checker: (any LearnedWordChecking)?
  /// Called once by the runner after language resolution.
  public var selectionProvider: (@MainActor (LLMProvider, String?) async -> LearnedWordCheckerSelection)?

  /// The user's "Enable Dictionary" switch, the same value `WordCorrectionStep`
  /// follows on every path (live settings sync, recovery snapshot, file-import
  /// freeze). Off means no learned word changes text (Codex PR-3 review).
  public var wordCorrectionEnabled: Bool = false

  /// The last invocation's counts and closed fallback reason (nil reason when it
  /// reached a decision). Content-free; it rides on the take's terminal row.
  public private(set) var lastOutcome: Outcome?

  /// The last invocation's counts and closed reason, never any text.
  public struct Outcome: Sendable, Equatable {
    public enum FallbackReason: String, Sendable, Equatable {
      case noChecker = "no_checker"
      case noCandidates = "no_candidates"
      case checkerError = "checker_error"
      /// The runner's cap cancelled the checker before it answered.
      case deadline = "deadline"
      case malformedAnswer = "malformed_answer"
    }
    public let flagged: Int
    public let approved: Int
    public let applied: Int
    public let contested: Int
    public let latencyMs: Int
    public let arm: String
    public let fallbackReason: FallbackReason?
  }

  /// Where the take's counts go: the take's `dictation.terminal` row
  /// (`TelemetryService.recordLearnedCheck`). A seam so tests observe the facts.
  var recordTerminalFacts: @MainActor (String, LearnedCheckTerminalFacts) -> Void = {
    TelemetryService.shared.recordLearnedCheck(takeID: $0, facts: $1)
  }

  public init() {}

  public var isEnabled: Bool {
    wordCorrectionEnabled
      && correctorVocabulary.terms.contains { $0.learnedAt != nil || !$0.learnedAliases.isEmpty }
  }

  func isEnabled(for context: TextProcessingContext) -> Bool {
    wordCorrectionEnabled
      && (context.frozenCorrectorVocabulary ?? correctorVocabulary).terms.contains {
        $0.learnedAt != nil || !$0.learnedAliases.isEmpty
      }
  }

  /// Runner cap. A checker answer that arrives later is discarded by the
  /// runner and the text continues unchanged. To be set from the measured
  /// per-question latency on the support floor before a checker is installed
  /// (plan §2.5 item 5); this value only bounds the inert step.
  public var maxDuration: Duration { .milliseconds(1500) }

  /// The step's OWN answer deadline, inside `maxDuration`. The runner's
  /// `withThrowingTimeout` cancels on its cap but its task group still waits for
  /// the cancelled child, so a checker that ignores cancellation could hold the
  /// take past the cap (Codex PR-3 review). The step instead races the checker
  /// against this clock and returns the unchanged text the moment it passes,
  /// never awaiting the late checker.
  var answerDeadline: Duration = .milliseconds(1200)

  private enum Answer: Sendable {
    case decided([LearnedWordCheckDecision])
    case late
    case cancelled
    case failed
  }

  /// First of (checker answer, deadline) wins; the loser is cancelled and never
  /// awaited, so the caller resumes at the deadline whatever the checker does.
  private static func decide(
    _ checker: any LearnedWordChecking, _ questions: [LearnedWordCheckQuestion],
    within deadline: Duration
  ) async -> Answer {
    let once = ResumeOnce()
    return await withCheckedContinuation { (continuation: CheckedContinuation<Answer, Never>) in
      let work = Task {
        let answer: Answer
        do {
          answer = .decided(try await checker.decide(questions))
        } catch is CancellationError {
          answer = .cancelled
        } catch {
          answer = .failed
        }
        if once.claim() { continuation.resume(returning: answer) }
      }
      Task {
        try? await Task.sleep(for: deadline)
        if once.claim() {
          work.cancel()
          continuation.resume(returning: .late)
        }
      }
    }
  }

  public func process(_ context: TextProcessingContext) async throws -> TextProcessingContext {
    let selection = context.frozenLearnedWordChecker
    let checker = selection?.checker ?? (selection == nil ? self.checker : nil)
    defer {
      if let outcome = lastOutcome {
        // #3105: only live dictation has a take id and a terminal row.
        if let takeID = context.takeID {
          recordTerminalFacts(
            takeID,
            LearnedCheckTerminalFacts(
              flagged: outcome.flagged, approved: outcome.approved, applied: outcome.applied,
              contested: outcome.contested, latencyMs: outcome.latencyMs, arm: outcome.arm,
              fallbackReason: outcome.fallbackReason?.rawValue,
              checkerIdentity: selection?.identity ?? checker?.armName,
              checkerStatus: checker == nil ? "no_checker" : "ran",
              absenceReason: checker == nil
                ? (selection?.absence?.code ?? LearnedWordCheckerAbsence.serverUnavailable.code)
                : nil))
        }
        Task {
          await AppLogger.shared.log(
            "LearnedWordCheck: flagged=\(outcome.flagged) approved=\(outcome.approved) applied=\(outcome.applied) contested=\(outcome.contested) latency_ms=\(outcome.latencyMs) arm=\(outcome.arm) reason=\(outcome.fallbackReason?.rawValue ?? "none")",
            level: .info, category: "Pipeline")
        }
      }
    }
    lastOutcome = nil
    guard let checker else {
      lastOutcome = Outcome(
        flagged: 0, approved: 0, applied: 0, contested: 0, latencyMs: 0,
        arm: "none", fallbackReason: .noChecker)
      return context
    }
    let vocabulary = context.frozenCorrectorVocabulary ?? correctorVocabulary
    let learned = LearnedWordCandidates.learnedWords(from: vocabulary.terms)
    let questions = LearnedWordCandidates.questions(
      for: context.text, learned: learned,
      language: context.englishRulesVetoed ? nil : context.language)
    let start = ContinuousClock.now
    func outcome(approved: Int, applied: Int, contested: Int, reason: Outcome.FallbackReason?)
      -> Outcome
    {
      let elapsed = ContinuousClock.now - start
      return Outcome(
        flagged: questions.count, approved: approved, applied: applied, contested: contested,
        latencyMs: Int(elapsed.components.seconds) * 1000
          + Int(elapsed.components.attoseconds / 1_000_000_000_000_000),
        arm: checker.armName, fallbackReason: reason)
    }
    guard !questions.isEmpty else {
      lastOutcome = outcome(approved: 0, applied: 0, contested: 0, reason: .noCandidates)
      return context
    }
    let decisions: [LearnedWordCheckDecision]
    switch await Self.decide(checker, questions, within: answerDeadline) {
    case .decided(let answer):
      decisions = answer
    case .late, .cancelled:
      lastOutcome = outcome(approved: 0, applied: 0, contested: 0, reason: .deadline)
      return context
    case .failed:
      lastOutcome = outcome(approved: 0, applied: 0, contested: 0, reason: .checkerError)
      return context
    }
    // One decision per question, by id, or the answer is not trusted at all.
    let ids = decisions.map(\.questionID)
    guard ids.count == questions.count, Set(ids) == Set(questions.map(\.id)) else {
      lastOutcome = outcome(approved: 0, applied: 0, contested: 0, reason: .malformedAnswer)
      return context
    }
    let result = LearnedWordSpanApplier.apply(
      text: context.text, questions: questions, decisions: decisions,
      scoresComparable: checker.scoresAreComparable)
    lastOutcome = outcome(
      approved: decisions.filter(\.approved).count, applied: result.applied,
      contested: result.contested, reason: nil)
    var updated = context
    updated.text = result.text
    return updated
  }
}

/// Lets exactly one of two racing tasks resume a continuation.
private final class ResumeOnce: @unchecked Sendable {
  private let lock = NSLock()
  private var claimed = false

  func claim() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if claimed { return false }
    claimed = true
    return true
  }
}
