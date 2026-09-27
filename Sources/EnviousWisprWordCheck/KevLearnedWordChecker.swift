import EnviousWisprCore
import Foundation

/// The learned-word checker for every polish engine without one of its own (#3242). Each
/// question becomes Kev's training state: the listed word, the context as written, the same
/// context with the listed word in place, and the span it replaces. Approved when p(said) reaches
/// the contract's cutoff, which was chosen on the tune half of the nine-language Judge 2 exam at a
/// 2% wrong-swap budget.
public struct KevLearnedWordChecker: LearnedWordChecking {
  private let model: KevWordCheckModel
  private let threshold: Double
  private let revision: String

  public init(model: KevWordCheckModel, contract: KevContract) {
    self.model = model
    threshold = contract.threshold
    revision = contract.revision
  }

  public var armName: String { "kev:\(revision)" }
  /// Probabilities from one model and one cutoff, so two approved spots can be ranked.
  public var scoresAreComparable: Bool { true }

  /// The state Kev reads for one question. Public so parity tests pin it.
  public static func state(for question: LearnedWordCheckQuestion) -> String {
    KevEncoding.stateText(
      listedWord: question.word, asWritten: question.contextText,
      withListedWord: question.contextRewritten,
      changedFrom: String(question.sentence[question.range]))
  }

  public func decide(_ questions: [LearnedWordCheckQuestion]) async throws
    -> [LearnedWordCheckDecision]
  {
    try Task.checkCancellation()
    let probabilities = try await model.probabilities(forStates: questions.map(Self.state(for:)))
    try Task.checkCancellation()
    return zip(questions, probabilities).map { question, p in
      LearnedWordCheckDecision(questionID: question.id, approved: p >= threshold, score: p)
    }
  }
}
