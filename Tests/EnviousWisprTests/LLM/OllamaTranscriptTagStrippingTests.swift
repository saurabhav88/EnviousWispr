import Foundation
import Testing

@testable import EnviousWisprCore
@testable import EnviousWisprLLM

/// #1948 removed the `<transcript>` sandwich from every Ollama prompt except EG-1's, so the
/// connector can no longer strip echoed wrapper tags unconditionally: on the plain-message
/// paths there is no wrapper to echo, and stripping would delete a user's OWN dictated
/// `<transcript>` text. That is the defect #1255 fixed for the cloud connectors when it
/// removed their sandwich; this suite pins both directions so removing the Ollama sandwich
/// cannot silently reintroduce it.
@Suite("Ollama transcript-tag stripping (#1948)")
struct OllamaTranscriptTagStrippingTests {

  /// Canned successful `/api/chat` response carrying `content`.
  private func connector(returning content: String) -> OllamaConnector {
    OllamaConnector(networkExecutor: { _ in
      let body: [String: Any] = [
        "message": ["role": "assistant", "content": content],
        "done_reason": "stop",
      ]
      let data = try JSONSerialization.data(withJSONObject: body)
      let response = HTTPURLResponse(
        url: URL(string: "http://localhost:11434/api/chat")!,
        statusCode: 200, httpVersion: nil, headerFields: nil)!
      return (data, response)
    })
  }

  private func config(model: String) -> LLMProviderConfig {
    LLMProviderConfig(
      model: model,
      apiKeyKeychainId: nil,
      outputTokens: .capped(256),
      temperature: 0,
      thinking: nil
    )
  }

  private func envelope(_ transcript: String) -> PromptEnvelope {
    PromptEnvelope(messages: [
      PromptMessage(role: .system, content: "system"),
      PromptMessage(role: .user, content: "Transcript to clean:\n\n\(transcript)"),
    ])
  }

  /// A local model is sent a plain user message, so tags in its OUTPUT can only have come
  /// from what the user dictated. They must survive.
  @Test("local model output keeps a user's own dictated <transcript> text")
  func localModelKeepsDictatedTags() async throws {
    let dictated = "the config needs a <transcript> tag around it"
    let result = try await connector(returning: dictated)
      .polish(envelope: envelope(dictated), config: config(model: "llama3.2"), onToken: nil)
    #expect(result.polishedText == dictated)
    #expect(result.polishedText.contains("<transcript>"))
  }

  /// Same for a hosted model, which is also sent a plain message (the fixed cloud prompt).
  @Test("hosted-style model output keeps a user's own dictated </transcript> text")
  func hostedModelKeepsDictatedTags() async throws {
    let dictated = "close it with </transcript> and save"
    let result = try await connector(returning: dictated)
      .polish(envelope: envelope(dictated), config: config(model: "gpt-oss:120b"), onToken: nil)
    #expect(result.polishedText.contains("</transcript>"))
  }

  /// The other direction, and the reason the cleanup still exists: EG-1 IS sent a
  /// `<TRANSCRIPT>` wrapper, so an echoed one is the model repeating our scaffolding and
  /// must still be stripped. Without this control, a change that simply disabled stripping
  /// everywhere would pass the two tests above.
  @Test("EG-1 output still has echoed wrapper tags stripped")
  func egOneStripsEchoedWrapper() async throws {
    let echoed = "<TRANSCRIPT>\nSend it Friday.\n</TRANSCRIPT>"
    let result = try await connector(returning: echoed)
      .polish(envelope: envelope("send it friday"), config: config(model: "eg-1"), onToken: nil)
    #expect(result.polishedText == "Send it Friday.")
    #expect(!result.polishedText.localizedCaseInsensitiveContains("<transcript>"))
  }

  /// Tag identity is the FIRST-PARTY authority, not the model's name shape: an ordinary
  /// model whose name merely resembles ours must be treated as plain-message.
  @Test("an eg-1 lookalike is treated as plain-message, not first-party")
  func lookalikeIsNotFirstParty() async throws {
    let dictated = "wrap it in <transcript> please"
    let result = try await connector(returning: dictated)
      .polish(envelope: envelope(dictated), config: config(model: "eg-10"), onToken: nil)
    #expect(result.polishedText.contains("<transcript>"))
  }
}
