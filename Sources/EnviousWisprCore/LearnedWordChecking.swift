import Foundation

/// One possible learned-word replacement in the original sentence.
public struct LearnedWordCheckQuestion: Sendable, Equatable {
  public let id: Int
  public let sentence: String
  public let range: Range<String.Index>
  public let word: String

  public init(id: Int, sentence: String, range: Range<String.Index>, word: String) {
    self.id = id
    self.sentence = sentence
    self.range = range
    self.word = word
  }

  public var rewritten: String {
    var result = sentence
    result.replaceSubrange(range, with: word)
    return result
  }
}

/// A score exists only when the checker arm produces a calibrated, comparable value.
public struct LearnedWordCheckDecision: Sendable, Equatable {
  public let questionID: Int
  public let approved: Bool
  public let score: Double?

  public init(questionID: Int, approved: Bool, score: Double? = nil) {
    self.questionID = questionID
    self.approved = approved
    self.score = score
  }
}

public protocol LearnedWordChecking: Sendable {
  var armName: String { get }
  var scoresAreComparable: Bool { get }
  func decide(_ questions: [LearnedWordCheckQuestion]) async throws -> [LearnedWordCheckDecision]
}
