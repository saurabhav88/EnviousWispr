import Foundation
import Testing

@testable import EnviousWisprCore
@testable import EnviousWisprLLM

/// #2649 contract delta C2, and the direct fix for #2634.
///
/// The reported user pulled `hf.co/superwhisper/s1-mini-GGUF:Q4_K_M` and got 183
/// attempts and 0 successes: 161 empty responses and 22 timeouts across two
/// releases, every take falling back to deterministic text with nothing said.
/// The cause is the GGUF's own Ollama template, which ends in an UNCLOSED
/// `<|im_start|>assistant\n<think>\n` — so over `/api/chat` the model is asked to
/// think and answers with thinking and no content.
@Suite("S1-mini raw transport (#2649, fixes #2634)", .tags(.productOutcome))
struct S1MiniRawTransportTests {

  static func envelope(transcript: String = "so um send the report by friday")
    -> PromptEnvelope
  {
    S1ControlLinePromptBuilder().build(
      input: PromptBuildInput(
        transcript: transcript,
        provider: .ollama,
        modelID: "hf.co/superwhisper/s1-mini-GGUF:Q4_K_M",
        appName: nil,
        language: nil,
        polishVocabulary: PolishVocabulary(terms: [], generation: 0),
        ollamaIsRemote: false),
      mode: .message)
  }

  /// THE fix. An OPEN think block is what returns nothing, so the row asserts
  /// the closed form rather than merely that a prefix exists.
  @Test("the assistant turn opens with a CLOSED, empty think block")
  func thinkBlockIsClosed() {
    #expect(
      S1MiniRawTransport.assistantPrefix == "<|im_start|>assistant\n<think>\n\n</think>\n\n")
    #expect(
      S1MiniRawTransport.assistantPrefix.contains("</think>"),
      "an unclosed think block is exactly what produced 161 empty responses")
  }

  @Test("the framed prompt is the card's ChatML shape, in order")
  func framedPromptShape() {
    let raw = S1MiniRawTransport.rawPrompt(for: Self.envelope())

    #expect(raw.hasPrefix("<|im_start|>system\n"))
    #expect(raw.hasSuffix(S1MiniRawTransport.assistantPrefix))
    #expect(raw.contains("<|im_start|>user\n"))
    // The system turn must come before the user turn, which a `contains` pair
    // cannot establish.
    let system = try! #require(raw.range(of: "<|im_start|>system"))
    let user = try! #require(raw.range(of: "<|im_start|>user"))
    #expect(system.lowerBound < user.lowerBound)
  }

  /// The prompt text has ONE owner. This file frames; it must never restate.
  @Test("the framed prompt carries the builder's text, not a second copy")
  func textComesFromTheOwner() {
    let raw = S1MiniRawTransport.rawPrompt(for: Self.envelope())
    #expect(raw.contains(S1ControlLinePromptBuilder.systemPrompt))
    #expect(raw.contains(S1ControlSettings.default.controlLine))
    #expect(raw.contains("so um send the report by friday"))
  }

  @Test("the request body uses the raw endpoint contract")
  func requestBodyIsRaw() {
    let body = S1MiniRawTransport.makeRequestBody(
      model: "hf.co/superwhisper/s1-mini-GGUF:Q4_K_M", envelope: Self.envelope(),
      maxTokens: 512, temperature: 0)

    #expect(body["raw"] as? Bool == true, "without raw, Ollama applies the broken template")
    #expect(body["stream"] as? Bool == false)
    #expect((body["prompt"] as? String)?.hasSuffix(S1MiniRawTransport.assistantPrefix) == true)
    // No `messages` key: that is the chat shape, and sending both would let a
    // future edit silently fall back to the endpoint that returns nothing.
    #expect(body["messages"] == nil)

    let options = try! #require(body["options"] as? [String: Any])
    #expect(options["num_predict"] as? Int == 512)
    #expect(options["temperature"] as? Double == 0)
    // With `raw: true` Ollama applies no template and therefore supplies no stop
    // sequence, so the model would run past the end of its turn into a second one.
    #expect((options["stop"] as? [String])?.contains("<|im_end|>") == true)
  }

  /// No `think` key, in any form. Sending one is the #2634 failure mode: the
  /// capability rule that reaches thinking-capable Ollama models returned zero
  /// characters of content after 11.6 seconds on this model.
  @Test("no thinking parameter is sent, in any shape")
  func noThinkingParameter() {
    let body = S1MiniRawTransport.makeRequestBody(
      model: "hf.co/superwhisper/s1-mini-GGUF:Q4_K_M", envelope: Self.envelope(),
      maxTokens: 512, temperature: 0)
    #expect(body["think"] == nil)
    let options = try! #require(body["options"] as? [String: Any])
    #expect(options["think"] == nil)
  }
}
