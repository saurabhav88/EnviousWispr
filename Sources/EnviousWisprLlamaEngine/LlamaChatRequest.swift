import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprLocalPolish
import Foundation

/// The chat-completions request a bundled model on `llama-server` is sent (#1271, #2649).
///
/// This was the request half of the EG-1 connector for the llama engine. EG-1 now runs on its
/// own engine with its own connector (#4473), and S1-mini is the one model that still sends
/// this request, so the builder lives here on its own: same wire format as before, no
/// keychain (the per-launch bearer token comes from the endpoint), temperature from the
/// caller's configuration.
enum LlamaChatRequest {
  /// Build the chat-completions body (#1710). Static and pure for fixture
  /// testing. The truncation policy depends on the computed cap; an
  /// uncapped request is an invariant breach and throws through the
  /// ordinary limb-failure path.
  static func makeBody(
    system: String, user: String, config: LLMProviderConfig,
    hasLearnedWordAdapter: Bool = false
  ) throws -> [String: Any] {
    guard case .capped(let maxTokens) = config.outputTokens else {
      throw LLMError.requestFailed("Local polish requires an explicit output-token cap")
    }
    let body: [String: Any] = [
      "model": config.model,
      "messages": [
        ["role": "system", "content": system],
        ["role": "user", "content": user],
      ],
      "max_tokens": maxTokens,
      "temperature": config.temperature,
    ]
    return withLearnedWordAdapterOff(body, hasLearnedWordAdapter: hasLearnedWordAdapter)
  }

  /// The one owner of how a non-checker request rides a server that loaded the learned-word
  /// adapter (#3105): the adapter at scale 0 and the polish slot, so the checker's eight slots
  /// stay its own. The bundled server applies a loaded adapter at full scale to any request that
  /// names none, so a request without these fields would be answered by the checker's weights.
  /// Without an adapter the body is unchanged.
  static func withLearnedWordAdapterOff(
    _ body: [String: Any], hasLearnedWordAdapter: Bool
  ) -> [String: Any] {
    guard hasLearnedWordAdapter else { return body }
    var adapted = body
    adapted["lora"] = [["id": 0 as Int, "scale": 0.0 as Double] as [String: Any]]
    adapted["id_slot"] = EGOneSlots.polish
    return adapted
  }
}
