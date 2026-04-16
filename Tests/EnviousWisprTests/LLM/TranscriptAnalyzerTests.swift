import Testing

@testable import EnviousWisprCore
@testable import EnviousWisprLLM

@Suite("TranscriptAnalyzer")
struct TranscriptAnalyzerTests {

  // MARK: - Word count boundaries

  @Test("34 words with no cues -> inline")
  func boundary34Words() {
    let text = Array(repeating: "word", count: 34).joined(separator: " ")
    #expect(TranscriptAnalyzer.analyzeMode(transcript: text, appName: "Slack") == .inline)
  }

  @Test("35 words with no cues -> inline (boundary)")
  func boundary35Words() {
    let text = Array(repeating: "word", count: 35).joined(separator: " ")
    #expect(TranscriptAnalyzer.analyzeMode(transcript: text, appName: "Slack") == .inline)
  }

  @Test("36 words with no cues -> message")
  func boundary36Words() {
    let text = Array(repeating: "word", count: 36).joined(separator: " ")
    #expect(TranscriptAnalyzer.analyzeMode(transcript: text, appName: "Slack") == .message)
  }

  @Test("109 words -> message")
  func boundary109Words() {
    let text = Array(repeating: "word", count: 109).joined(separator: " ")
    #expect(TranscriptAnalyzer.analyzeMode(transcript: text, appName: "Slack") == .message)
  }

  @Test("110 words -> message (boundary)")
  func boundary110Words() {
    let text = Array(repeating: "word", count: 110).joined(separator: " ")
    #expect(TranscriptAnalyzer.analyzeMode(transcript: text, appName: "Slack") == .message)
  }

  @Test("111 words -> structured")
  func boundary111Words() {
    let text = Array(repeating: "word", count: 111).joined(separator: " ")
    #expect(TranscriptAnalyzer.analyzeMode(transcript: text, appName: "Slack") == .structured)
  }

  // MARK: - List cue detection

  @Test("short text with list cues -> message (cues override length)")
  func shortWithListCues() {
    let text = "first I need to call the dentist and second pick up groceries"
    // ~12 words, has "first" + "second"
    #expect(TranscriptAnalyzer.analyzeMode(transcript: text, appName: "Slack") == .message)
  }

  @Test("34 words with 'three things' -> message")
  func shortWithThreeThings() {
    let words = Array(repeating: "word", count: 30).joined(separator: " ")
    let text = "three things I need " + words
    #expect(TranscriptAnalyzer.analyzeMode(transcript: text, appName: "Slack") == .message)
  }

  @Test("75 words with list cues -> structured (cues lower threshold)")
  func mediumWithListCues() {
    let words = Array(repeating: "word", count: 70).joined(separator: " ")
    let text = "first " + words + " second thing"
    #expect(TranscriptAnalyzer.analyzeMode(transcript: text, appName: "Slack") == .structured)
  }

  // MARK: - Specific cue patterns

  @Test("'pros and cons' detected as list cue")
  func prosAndCons() {
    let text = "let me talk about the pros and cons of this approach we have been discussing"
    #expect(TranscriptAnalyzer.detectListCues(in: text))
  }

  @Test("'action items' detected as list cue")
  func actionItems() {
    let text = "here are the action items from today's meeting"
    #expect(TranscriptAnalyzer.detectListCues(in: text))
  }

  @Test("'number one' detected as list cue")
  func numberOne() {
    let text = "number one we need to fix the bug and number two deploy the fix"
    #expect(TranscriptAnalyzer.detectListCues(in: text))
  }

  @Test("'next steps' detected as list cue")
  func nextSteps() {
    let text = "so the next steps are to review the PR and merge it"
    #expect(TranscriptAnalyzer.detectListCues(in: text))
  }

  @Test("'agenda' detected as list cue")
  func agenda() {
    let text = "the agenda for today is to discuss the roadmap"
    #expect(TranscriptAnalyzer.detectListCues(in: text))
  }

  @Test("plain prose without cues returns false")
  func noCues() {
    let text =
      "I think we should ship this behind a flag because the onboarding flow still has edge cases"
    #expect(!TranscriptAnalyzer.detectListCues(in: text))
  }

  @Test("'to do' in ordinary prose is NOT a false positive")
  func toDoFalsePositive() {
    let text = "I need to do that tomorrow before the meeting"
    #expect(!TranscriptAnalyzer.detectListCues(in: text))
  }

  @Test("'things to do' IS a valid list cue")
  func thingsToDo() {
    let text = "here are the things to do before we launch"
    #expect(TranscriptAnalyzer.detectListCues(in: text))
  }

  @Test("case insensitive cue detection")
  func caseInsensitive() {
    let text = "FIRST we do this THEN we do that"
    #expect(TranscriptAnalyzer.detectListCues(in: text))
  }

  // MARK: - Conservative nil-app routing

  @Test("nil appName with 111 words and no cues -> message (conservative)")
  func nilAppLongNoCues() {
    let text = Array(repeating: "word", count: 111).joined(separator: " ")
    #expect(TranscriptAnalyzer.analyzeMode(transcript: text, appName: nil) == .message)
  }

  @Test("nil appName with 111 words and list cues -> structured")
  func nilAppLongWithCues() {
    let words = Array(repeating: "word", count: 108).joined(separator: " ")
    let text = "first " + words + " then finally done"
    #expect(TranscriptAnalyzer.analyzeMode(transcript: text, appName: nil) == .structured)
  }

  @Test("nil appName with 75 words and list cues -> message (conservative, needs >110)")
  func nilAppMediumWithCues() {
    let words = Array(repeating: "word", count: 70).joined(separator: " ")
    let text = "first " + words + " then done"
    #expect(TranscriptAnalyzer.analyzeMode(transcript: text, appName: nil) == .message)
  }

  // MARK: - Empty/minimal input

  @Test("empty string -> inline")
  func emptyTranscript() {
    #expect(TranscriptAnalyzer.analyzeMode(transcript: "", appName: nil) == .inline)
  }

  @Test("single word -> inline")
  func singleWord() {
    #expect(TranscriptAnalyzer.analyzeMode(transcript: "hello", appName: "Slack") == .inline)
  }
}
