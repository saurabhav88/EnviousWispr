import Foundation
import Testing

@testable import EnviousWisprCore
@testable import EnviousWisprLLM

/// #2649 contract delta C1, at the connector.
///
/// The rows that matter are the ones proving this connector did NOT inherit a
/// blanket "empty is valid", and the ones proving it did NOT lose the guard it
/// shares with EG-1. A freshly authored sibling drops an inherited guard without
/// noticing; that is the failure this suite exists to make loud.
@Suite("S1-mini connector empty and truncation rules (#2649)", .tags(.driftGuard))
struct S1MiniConnectorTests {

  static func body(content: String, finish: String = "stop") -> Data {
    let json: [String: Any] = [
      "choices": [["message": ["content": content], "finish_reason": finish]]
    ]
    return try! JSONSerialization.data(withJSONObject: json)
  }

  static func userMessage(_ transcript: String) -> String {
    "\(S1ControlSettings.default.controlLine)\n\(transcript)"
  }

  @Test("an empty answer to filler-only input is a valid result, not a crash")
  func emptyForFillerIsValid() throws {
    let result = try S1MiniConnector.parseSuccess(
      data: Self.body(content: ""), userMessage: Self.userMessage("um uh"))
    #expect(result.polishedText == "")
  }

  /// The load-bearing row. #2634's entire signal was 161 empty responses from a
  /// user whose polish never worked; a connector that accepted every empty
  /// would have hidden exactly that.
  @Test("an empty answer to real words is still a failure")
  func emptyForRealWordsStillFails() {
    #expect(throws: (any Error).self) {
      try S1MiniConnector.parseSuccess(
        data: Self.body(content: ""),
        userMessage: Self.userMessage("send the report by friday"))
    }
  }

  /// The inherited guard. Measured on the shipped binary: an input that FITS the
  /// window can still exhaust it during generation and come back HTTP 200 with
  /// 21,583 characters of runaway text. Reading the status alone pastes it.
  @Test("a length-terminated answer is refused even when it has content")
  func lengthFinishIsRefused() {
    #expect(throws: (any Error).self) {
      try S1MiniConnector.parseSuccess(
        data: Self.body(content: "a long partial rewrite that never ended", finish: "length"),
        userMessage: Self.userMessage("send the report by friday"))
    }
    // And it is refused for filler input too, so the empty rule cannot be used
    // as a way past the truncation rule.
    #expect(throws: (any Error).self) {
      try S1MiniConnector.parseSuccess(
        data: Self.body(content: "", finish: "length"),
        userMessage: Self.userMessage("um uh"))
    }
  }

  @Test("ordinary content is returned trimmed")
  func ordinaryContent() throws {
    let result = try S1MiniConnector.parseSuccess(
      data: Self.body(content: "  I need to send the report by Thursday.\n"),
      userMessage: Self.userMessage("so um i need to send the report by friday no wait thursday"))
    #expect(result.polishedText == "I need to send the report by Thursday.")
  }

  @Test("a malformed body is a local-server hiccup, not a valid empty")
  func malformedBodyFails() {
    #expect(throws: (any Error).self) {
      try S1MiniConnector.parseSuccess(
        data: Data("not json".utf8), userMessage: Self.userMessage("um"))
    }
  }

  // MARK: - Recovering the transcript from the user message

  @Test("the control line is dropped so the empty rule sees the transcript")
  func transcriptRecovery() {
    #expect(
      S1MiniConnector.transcript(fromUserMessage: Self.userMessage("um uh")) == "um uh")
    #expect(
      S1MiniConnector.transcript(fromUserMessage: Self.userMessage("line one\nline two"))
        == "line one\nline two")
  }

  /// A message that is not the expected shape falls back to using the WHOLE
  /// text. That direction is safe and the row states why: the control line
  /// contains ordinary words, so the fallback can only make an empty answer look
  /// like a failure, never like a valid empty.
  @Test("an unexpected message shape fails toward reporting a failure")
  func unexpectedShapeIsSafe() {
    let odd = "no control line here"
    #expect(S1MiniConnector.transcript(fromUserMessage: odd) == odd)
    // And the whole control line, if it ever reached the classifier, must not
    // read as filler. Every trained combination, not only the default: the
    // pickers (#2649) can put any of them on the wire.
    for styling in S1Styling.allCases {
      for structure in S1Structure.allCases {
        for context in S1Context.allCases {
          let line = S1ControlSettings(styling: styling, structure: structure, context: context)
            .controlLine
          #expect(
            LocalPolishEmptyDisposition.classify(input: line) == .unexpectedEmpty,
            Comment(rawValue: line))
          // And the transcript recovery must still find the transcript behind it.
          #expect(S1MiniConnector.transcript(fromUserMessage: "\(line)\nhello there") == "hello there")
        }
      }
    }
  }
}
