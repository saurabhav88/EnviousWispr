import Foundation
import EnviousWisprCore

public enum LearnedWordSpanApplier: Sendable {
  private struct ApprovedSpan {
    let range: Range<String.Index>
    let word: String
    let score: Double?
  }

  public static func apply(
    text: String,
    questions: [LearnedWordCheckQuestion],
    decisions: [LearnedWordCheckDecision],
    scoresComparable: Bool
  ) -> (text: String, applied: Int, contested: Int) {
    guard questions.isEmpty == false, decisions.isEmpty == false else {
      return (text, 0, 0)
    }

    let questionCounts = Dictionary(questions.map { ($0.id, 1) }, uniquingKeysWith: +)
    let decisionCounts = Dictionary(decisions.map { ($0.questionID, 1) }, uniquingKeysWith: +)
    let decisionsByID = Dictionary(
      decisions.map { ($0.questionID, $0) }, uniquingKeysWith: { first, _ in first })
    var approved = [ApprovedSpan]()
    for question in questions {
      guard questionCounts[question.id] == 1,
            decisionCounts[question.id] == 1,
            let decision = decisionsByID[question.id], decision.approved,
            question.sentence.utf8.elementsEqual(text.utf8),
            question.range.lowerBound < question.range.upperBound,
            text.indices.contains(question.range.lowerBound),
            question.range.upperBound == text.endIndex
              || text.indices.contains(question.range.upperBound)
      else { continue }
      approved.append(ApprovedSpan(
        range: question.range, word: question.word,
        score: decision.score?.isFinite == true ? decision.score : nil))
    }

    var removed = Set<Int>()
    for left in approved.indices {
      for right in approved.indices where right > left {
        let a = approved[left]
        let b = approved[right]
        guard a.word.utf8.elementsEqual(b.word.utf8) else { continue }
        if a.range == b.range {
          removed.insert(right)
        } else if contains(a.range, b.range) {
          removed.insert(left)
        } else if contains(b.range, a.range) {
          removed.insert(right)
        }
      }
    }

    // Resolve scored claims from highest to lowest. Once a claim loses, it
    // cannot also eliminate another overlapping claim farther along the text.
    if scoresComparable {
      let scored = approved.indices.filter { approved[$0].score != nil }.sorted {
        let left = approved[$0].score ?? 0
        let right = approved[$1].score ?? 0
        return left == right ? $0 < $1 : left > right
      }
      for winner in scored where removed.contains(winner) == false {
        for loser in scored where loser != winner && removed.contains(loser) == false {
          let a = approved[winner]
          let b = approved[loser]
          guard let aScore = a.score, let bScore = b.score, aScore > bScore,
                a.word.utf8.elementsEqual(b.word.utf8) == false,
                overlaps(a.range, b.range)
          else { continue }
          removed.insert(loser)
        }
      }
    }

    var contested = Set<Int>()
    for left in approved.indices where removed.contains(left) == false {
      for right in approved.indices where right > left && removed.contains(right) == false {
        if overlaps(approved[left].range, approved[right].range) {
          contested.insert(left)
          contested.insert(right)
        }
      }
    }

    let winners = approved.indices.filter {
      removed.contains($0) == false && contested.contains($0) == false
    }.map { approved[$0] }.sorted { $0.range.lowerBound > $1.range.lowerBound }
    var rewritten = text
    for winner in winners { rewritten.replaceSubrange(winner.range, with: winner.word) }
    return (rewritten, winners.count, contested.count)
  }

  private static func contains(_ outer: Range<String.Index>, _ inner: Range<String.Index>) -> Bool {
    outer.lowerBound <= inner.lowerBound && inner.upperBound <= outer.upperBound
  }

  private static func overlaps(_ a: Range<String.Index>, _ b: Range<String.Index>) -> Bool {
    a.lowerBound < b.upperBound && b.lowerBound < a.upperBound
  }
}
