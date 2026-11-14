import EnviousWisprCore
import Foundation

/// The saved version that was shown when the user requested a new polish.
struct HistoryPolishCandidate: Sendable {
  let base: Transcript
  let text: String
  let turns: [Turn]?
  let provider: LLMProvider
  let model: String
  var egOneSize: EGOneSize? = nil
  var comparisonCurrentText: String? = nil
  var comparisonNewText: String? = nil

  func matches(_ current: Transcript) -> Bool {
    current.id == base.id && current.meetingID == base.meetingID
      && current.isImported == base.isImported
      && current.importAttemptID == base.importAttemptID
      && current.meetingTranscriptGeneration == base.meetingTranscriptGeneration
      && current.text.utf8.elementsEqual(base.text.utf8)
      && current.polishedText == base.polishedText && current.processedText == base.processedText
      && current.llmProvider == base.llmProvider && current.llmModel == base.llmModel
      && current.historyPolishEGOneSize == base.historyPolishEGOneSize
      && current.preferredVersion == base.preferredVersion && current.turns == base.turns
  }
}
