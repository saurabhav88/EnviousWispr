import EnviousWisprCore
import Foundation

/// Serialises a prompt envelope into S1-mini's trained ChatML frame for
/// Ollama's `/api/generate` with `raw: true` (#2649, contract delta C2).
///
/// **Why this exists at all**, from #2634: one user pulled
/// `hf.co/superwhisper/s1-mini-GGUF:Q4_K_M` and got 183 attempts and 0
/// successes across two releases — 161 empty responses and 22 timeouts. Every
/// take fell back to deterministic text and nothing ever told them.
///
/// The cause is in the GGUF's own Ollama template, which ends with an UNCLOSED
/// `<|im_start|>assistant\n<think>\n`. Over `/api/chat` the model is therefore
/// asked to think, and it answers with thinking and no content. Five chat-shaped
/// variants were measured and every one returned empty; only the raw endpoint
/// with the trained prefix works.
///
/// **This file carries NO prompt text.** The system prompt and the control line
/// belong to `S1ControlLinePromptBuilder`, which is pinned byte-for-byte against
/// the published card. All that happens here is framing — if this file held its
/// own copy of either string, the prompt would exist twice with only one copy
/// under test, which is the duplication the single-owner rule exists to stop.
enum S1MiniRawTransport {

  /// The assistant prefix, written out exactly as the model card specifies:
  /// an empty think block, CLOSED, with two newlines inside it and two after.
  /// Closing it is the entire fix — leaving it open is what returns nothing.
  static let assistantPrefix = "<|im_start|>assistant\n<think>\n\n</think>\n\n"

  /// Frame an envelope. Roles are joined in order rather than assumed to be
  /// exactly one system and one user, so an envelope shape change cannot
  /// silently drop a message.
  static func rawPrompt(for envelope: PromptEnvelope) -> String {
    var frame = ""
    for message in envelope.messages {
      let role: String =
        switch message.role {
        case .system: "system"
        case .user: "user"
        case .assistant: "assistant"
        }
      frame += "<|im_start|>\(role)\n\(message.content)<|im_end|>\n"
    }
    return frame + assistantPrefix
  }

  /// The `/api/generate` body. `raw: true` is what makes Ollama send the prompt
  /// verbatim instead of running the GGUF's own template, which is the template
  /// that leaves the think block open.
  static func makeRequestBody(
    model: String, envelope: PromptEnvelope, maxTokens: Int, temperature: Double
  ) -> [String: Any] {
    [
      "model": model,
      "prompt": rawPrompt(for: envelope),
      "raw": true,
      "stream": false,
      "keep_alive": "60m",
      "options": [
        "num_predict": maxTokens,
        "temperature": temperature,
        // The trained stop token. With `raw: true` Ollama applies no template,
        // so it also supplies no stop sequence — without this the model runs
        // past the end of its turn and into a second one.
        "stop": ["<|im_end|>"],
      ],
    ]
  }
}
