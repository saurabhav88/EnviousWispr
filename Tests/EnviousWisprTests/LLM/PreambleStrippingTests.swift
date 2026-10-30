import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprLLM

@Suite("Preamble Stripping")
struct PreambleStrippingTests {

  // MARK: - No-op cases

  @Test("clean text passes through unchanged")
  func cleanTextUnchanged() {
    let input = "The quick brown fox jumps over the lazy dog."
    #expect(input.strippingLLMPreamble(dictation: "please send the invoice") == input)
  }

  @Test("empty string returns empty")
  func emptyString() {
    #expect("".strippingLLMPreamble(dictation: "please send the invoice") == "")
  }

  @Test("whitespace-only string returns empty")
  func whitespaceOnly() {
    #expect("   \n\n  ".strippingLLMPreamble(dictation: "please send the invoice") == "")
  }

  // MARK: - Acknowledgment stripping

  @Test(
    "acknowledgment patterns stripped",
    arguments: [
      ("Certainly! Here is your text.", "Here is your text."),
      ("Sure! The answer is yes.", "The answer is yes."),
      ("Sure, I can help with that.", "I can help with that."),
      ("Of course! Here you go.", "Here you go."),
      ("Got it. Processing now.", "Processing now."),
      ("Got it! Working on it.", "Working on it."),
      ("Absolutely! Done.", "Done."),
      ("Here you go: some text", "some text"),
    ])
  func acknowledgmentStripped(input: String, expected: String) {
    #expect(input.strippingLLMPreamble(dictation: "please send the invoice") == expected)
  }

  // MARK: - Preamble line stripping

  @Test(
    "preamble lines stripped",
    arguments: [
      ("Here is the corrected version:\nThe actual text.", "The actual text."),
      ("Below is the cleaned transcript:\nHello world.", "Hello world."),
      ("The corrected text:\nFixed version here.", "Fixed version here."),
      ("The cleaned up version:\nNice and clean.", "Nice and clean."),
      ("The polished transcript:\nPolished text.", "Polished text."),
      ("The rewritten text:\nRewritten version.", "Rewritten version."),
      ("Corrected version:\nFixed.", "Fixed."),
      ("Cleaned transcript:\nClean.", "Clean."),
      ("Polished version:\nShiny.", "Shiny."),
      // #2795: a wrapper line still strips, with and without an acknowledgment.
      ("Here is the cleaned transcript:\nCall.", "Call."),
      ("Sure! Here is the cleaned transcript:\nCall.", "Call."),
      // #2795: a dictated list lead-in that happens to start with "here" and end
      // with ":" is content, not a wrapper, and survives.
      (
        "Here are the things we should do before lunch:\n- Call.",
        "Here are the things we should do before lunch:\n- Call."
      ),
      ("Below the fold, three items:\n- One.", "Below the fold, three items:\n- One."),
      // #2795 second pass: a wrapper noun INSIDE another word is not a wrapper.
      ("Here are the conversion steps:\n- Open Settings.", "Here are the conversion steps:\n- Open Settings."),
      ("Here are the textile suppliers:\n- One.", "Here are the textile suppliers:\n- One."),
      ("Here's the cleaned up text:\nCall.", "Call."),
      ("Below is your transcript:\nCall.", "Call."),
      // #2795 cloud review r2: the adjective set covers what models actually emit.
      ("Here is the revised transcript:\nHello.", "Hello."),
      ("Here is the updated text:\nHello.", "Hello."),
      ("Here is the final version:\nHello.", "Hello."),
    ])
  func preambleLinesStripped(input: String, expected: String) {
    #expect(input.strippingLLMPreamble(dictation: "please send the invoice") == expected)
  }

  // MARK: - Transcript wrapper

  @Test("transcript tags removed")
  func transcriptTagsRemoved() {
    let input = "<transcript>Hello world</transcript>"
    #expect(input.strippingTranscriptTags() == "Hello world")
  }

  @Test("unclosed transcript tag removed")
  func unclosedTranscriptTag() {
    let input = "<transcript>Hello world"
    #expect(input.strippingTranscriptTags() == "Hello world")
  }

  // #1255 Codex r5: the fixed cloud prompt sends no <transcript> sandwich, so the cloud
  // connectors retain literal tags — a user who dictates them must get
  // them back verbatim, while preamble/acknowledgment stripping still applies.
  @Test("chatter policy leaves literal transcript tags for the transport adapter")
  func transcriptTagsPreservedOnCloudPath() {
    let literal = "<transcript>Hello world</transcript>"
    #expect(literal.strippingLLMPreamble(dictation: "please send the invoice") == literal)

    let withPreamble = "Here is the cleaned text:\n<transcript>keep me</transcript>"
    #expect(
      withPreamble.strippingLLMPreamble(dictation: "please send the invoice")
        == "<transcript>keep me</transcript>")
  }

  // MARK: - Combined patterns

  @Test("acknowledgment + preamble line both stripped")
  func combinedAcknowledgmentAndPreamble() {
    let input = "Certainly! Here is the corrected version:\nThe actual transcript text."
    #expect(input.strippingLLMPreamble(dictation: "please send the invoice") == "The actual transcript text.")
  }

  @Test("acknowledgment + transcript wrapper both stripped")
  func combinedAcknowledgmentAndWrapper() {
    let input = "Sure! <transcript>Hello world</transcript>"
    #expect(input.strippingTranscriptTags()
      .strippingLLMPreamble(dictation: "please send the invoice") == "Hello world")
  }

  // MARK: - False positive protection

  @Test("short colon line not matching preamble patterns preserved")
  func nonPreambleColonPreserved() {
    let input = "Summary:\nThe project is on track."
    #expect(input.strippingLLMPreamble(dictation: "please send the invoice") == "Summary:\nThe project is on track.")
  }

  @Test("user content starting with Sure preserved when not acknowledgment pattern")
  func sureInContentPreserved() {
    // "Sure" without ! or , is not an acknowledgment pattern
    let input = "Sure enough it worked."
    #expect(input.strippingLLMPreamble(dictation: "please send the invoice") == "Sure enough it worked.")
  }

  // MARK: - Idempotence

  @Test("one acknowledged wrapper needs no second pass")
  func idempotent() {
    let input = "Certainly! Here is the corrected version:\nThe transcript text."
    let once = input.strippingLLMPreamble(dictation: "please send the invoice")
    let twice = once.strippingLLMPreamble(dictation: "please send the invoice")
    #expect(once == twice)
  }
  @Test("dictated openings survive case, punctuation and wrapper layout",
    arguments: [
      ("sure I can do that tomorrow", "Sure, I can do that tomorrow."),
      ("got it I will send the file tonight", "Got it. I will send the file tonight."),
      ("OF COURSE I can help with that", "Of course! I can help with that."),
      ("absolutely let us do Thursday", "Absolutely! Let us do Thursday."),
      ("the corrected numbers for q3 are revenue four million",
       "The corrected numbers for Q3 are:\n- Revenue four million"),
      ("here’s the cleaned text for the report", "Here's the cleaned text:\nThe report is ready."),
      ("sure send the invoice today",
       "Sure! Here is the cleaned transcript:\nSure, send the invoice today.")
    ])
  func dictatedOpening(dictation: String, output: String) {
    #expect(output.strippingLLMPreamble(dictation: dictation) == output)
  }

  @Test("empty, zero-token or unclassifiable source never authorizes a deletion",
    arguments: ["", "...", "\u{0301}send the invoice"])
  func unknownSource(dictation: String) {
    let output = "Sure, I can send the invoice."
    #expect(output.strippingLLMPreamble(dictation: dictation) == output)
  }

  @Test("source normalization preserves output bytes rather than rewriting them")
  func canonicalSourceOnly() {
    let output = "The corrected re\u{0301}sume\u{0301}:\nThe report is ready."
    let cleaned = output.strippingLLMPreamble(dictation: "the corrected résumé is ready")
    #expect(Array(cleaned.utf8) == Array(output.utf8))
    #expect("Got it. I will send the invoice.".strippingLLMPreamble(
      dictation: "please send the invoice") == "I will send the invoice.")
  }

  @Test("each non-Apple provider uses the source-aware result boundary",
    arguments: [LLMProvider.openAI, .gemini, .claude, .ollama, .egOne, .s1Mini])
  func providerBoundary(provider: LLMProvider) throws {
    let output = "Sure, I can do that tomorrow."
    let result = try LLMResult(polishedText: output).removingModelChatter(
      dictation: "sure I can do that tomorrow", provider: provider)
    #expect(result.polishedText == output)
  }

  @Test("result adaptation preserves metadata and early-stop state")
  func resultFields() throws {
    let metadata = PolishMetadata(filterTripped: "fixture", filterFellBackToRaw: false)
    let original = LLMResult(
      polishedText: "Sure, I can do that tomorrow.", polishMetadata: metadata, stoppedEarly: true)
    let result = try original.removingModelChatter(
      dictation: "I can do that tomorrow", provider: .ollama)
    #expect(result.polishedText == "I can do that tomorrow.")
    #expect(result.polishMetadata == metadata)
    #expect(result.stoppedEarly == true)
    let apple = try original.removingModelChatter(
      dictation: "I can do that tomorrow", provider: .appleIntelligence)
    #expect(apple.polishedText == original.polishedText)
    #expect(apple.polishMetadata == metadata)
    #expect(apple.stoppedEarly == true)
  }

}
