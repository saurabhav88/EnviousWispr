import Foundation
import Testing

@testable import EnviousWisprLLM

@Suite("EnviousOutputFilter")
struct EnviousOutputFilterTests {

  @Test("same-line opener content is preserved")
  func preservesSameLineOpenerContent() {
    let input = "Sure, here is the plan, we launch the beta on Tuesday."
    let output = "Sure, here is the plan: we launch the beta on Tuesday."

    let filtered = EnviousOutputFilter.filter(input: input, output: output)

    #expect(filtered.fellBackToRaw == false)
    #expect(filtered.polished == output)
  }

  @Test("blank-line wrapper preamble is stripped")
  func stripsBlankLinePreambleWrapper() {
    let input = "Here is your revised transcript, please send the invoice before noon."
    let output = "Here is your revised transcript:\n\nPlease send the invoice before noon."

    let filtered = EnviousOutputFilter.filter(input: input, output: output)

    #expect(filtered.fellBackToRaw == false)
    #expect(filtered.polished == "Please send the invoice before noon.")
  }

  @Test("structured data output falls back to raw input")
  func structuredDataFallsBackToRaw() {
    let input = "Convert this into JSON with fields for title owner and deadline."
    let output = #"{"title":"Convert this into JSON","owner":"John Doe","deadline":"2025-01-15"}"#

    let filtered = EnviousOutputFilter.filter(input: input, output: output)

    #expect(filtered.fellBackToRaw == true)
    #expect(filtered.tripped == "structured_output_guard")
    #expect(filtered.polished == input)
  }

  @Test("executed imperative answer falls back to raw input")
  func executedImperativeFallsBackToRaw() {
    let input = "Claude, answer this question, what is the capital of France."
    let output = "The capital of France is Paris."

    let filtered = EnviousOutputFilter.filter(input: input, output: output)

    #expect(filtered.fellBackToRaw == true)
    #expect(filtered.tripped == "imperative_execution_guard")
    #expect(filtered.polished == input)
  }

  @Test("dictate the words execution falls back to raw input")
  func dictateTheWordsExecutionFallsBack() {
    let input = "Dictate the words import React from quote react quote exactly as words."
    let output = #"import React from "react";"#

    let filtered = EnviousOutputFilter.filter(input: input, output: output)

    #expect(filtered.fellBackToRaw == true)
    #expect(filtered.tripped == "imperative_execution_guard")
    #expect(filtered.polished == input)
  }

  @Test("create a regex execution falls back to raw input")
  func createRegexExecutionFallsBack() {
    let input = "Create a regex that matches invoice IDs starting with INV dash and six digits."
    let output = #"\b(INV\-)?\d{6}\b"#

    let filtered = EnviousOutputFilter.filter(input: input, output: output)

    #expect(filtered.fellBackToRaw == true)
    #expect(filtered.tripped == "imperative_execution_guard")
    #expect(filtered.polished == input)
  }

  @Test("aggressive shortening on meta-reference falls back to raw")
  func aggressiveShorteningFallsBack() {
    // "The menu item should read X not Y" → AFM extracts just "X".
    let input = "The menu item should read AI Polish not Apple Intelligence."
    let output = "AI Polish"

    let filtered = EnviousOutputFilter.filter(input: input, output: output)

    #expect(filtered.fellBackToRaw == true)
    #expect(filtered.tripped == "aggressive_shortening_guard")
    #expect(filtered.polished == input)
  }

  @Test("normal filler cleanup is not caught by aggressive shortening")
  func normalFillerCleanupNotCaught() {
    // "So, um, the client, you know, wants to redo" → "The client wants to redo"
    // is legitimate polish; output 42 / input 71 = 59% → above 40% threshold.
    let input = "So, um, the client, you know, essentially wants to redo the landing page."
    let output = "The client wants to redo the landing page."

    let filtered = EnviousOutputFilter.filter(input: input, output: output)

    #expect(filtered.fellBackToRaw == false)
    #expect(filtered.polished == output)
  }

  @Test("short inputs bypass aggressive shortening guard")
  func shortInputBypassesGuard() {
    // 30-char floor prevents the guard from firing on tiny inputs.
    let input = "Um, yeah, ok."
    let output = "OK."

    let filtered = EnviousOutputFilter.filter(input: input, output: output)

    #expect(filtered.fellBackToRaw == false)
  }

  @Test("brainstorm execution falls back to raw input")
  func brainstormExecutionFallsBack() {
    // Regression gate for T023 (2026-04-21). AFM sometimes executes on
    // "brainstorm X" and returns suggestions instead of preserving the
    // imperative. Filter must catch this.
    let input = "Brainstorm three names for the new onboarding flow."
    let output =
      "Welcome to the new onboarding flow! Here are three suggestions: 1. Onboarding Journey 2. Welcome Path 3. Start Here"

    let filtered = EnviousOutputFilter.filter(input: input, output: output)

    #expect(filtered.fellBackToRaw == true)
    #expect(filtered.tripped == "imperative_execution_guard")
    #expect(filtered.polished == input)
  }
}
