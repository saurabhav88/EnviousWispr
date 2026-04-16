import Foundation
import Testing

@testable import EnviousWisprLLM

@Suite("Preamble Stripping")
struct PreambleStrippingTests {

  // MARK: - No-op cases

  @Test("clean text passes through unchanged")
  func cleanTextUnchanged() {
    let input = "The quick brown fox jumps over the lazy dog."
    #expect(input.strippingLLMPreamble() == input)
  }

  @Test("empty string returns empty")
  func emptyString() {
    #expect("".strippingLLMPreamble() == "")
  }

  @Test("whitespace-only string returns empty")
  func whitespaceOnly() {
    #expect("   \n\n  ".strippingLLMPreamble() == "")
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
    #expect(input.strippingLLMPreamble() == expected)
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
    ])
  func preambleLinesStripped(input: String, expected: String) {
    #expect(input.strippingLLMPreamble() == expected)
  }

  // MARK: - Transcript wrapper

  @Test("transcript tags removed")
  func transcriptTagsRemoved() {
    let input = "<transcript>Hello world</transcript>"
    #expect(input.strippingLLMPreamble() == "Hello world")
  }

  @Test("unclosed transcript tag removed")
  func unclosedTranscriptTag() {
    let input = "<transcript>Hello world"
    #expect(input.strippingLLMPreamble() == "Hello world")
  }

  // MARK: - Combined patterns

  @Test("acknowledgment + preamble line both stripped")
  func combinedAcknowledgmentAndPreamble() {
    let input = "Certainly! Here is the corrected version:\nThe actual transcript text."
    #expect(input.strippingLLMPreamble() == "The actual transcript text.")
  }

  @Test("acknowledgment + transcript wrapper both stripped")
  func combinedAcknowledgmentAndWrapper() {
    let input = "Sure! <transcript>Hello world</transcript>"
    #expect(input.strippingLLMPreamble() == "Hello world")
  }

  // MARK: - False positive protection

  @Test("short colon line not matching preamble patterns preserved")
  func nonPreambleColonPreserved() {
    let input = "Summary:\nThe project is on track."
    #expect(input.strippingLLMPreamble() == "Summary:\nThe project is on track.")
  }

  @Test("user content starting with Sure preserved when not acknowledgment pattern")
  func sureInContentPreserved() {
    // "Sure" without ! or , is not an acknowledgment pattern
    let input = "Sure enough it worked."
    #expect(input.strippingLLMPreamble() == "Sure enough it worked.")
  }

  // MARK: - Idempotence

  @Test("stripping is idempotent")
  func idempotent() {
    let input = "Certainly! Here is the corrected version:\nThe transcript text."
    let once = input.strippingLLMPreamble()
    let twice = once.strippingLLMPreamble()
    #expect(once == twice)
  }
}
