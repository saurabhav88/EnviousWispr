import Foundation

/// What a chat-completions answer from the bundled `llama-server` means, for the parts both
/// llama-served connectors agree on (#4473).
///
/// These two helpers lived on `LocalPolishTransport`. The transport now moves bytes only and
/// knows no response shape, so they sit with the connectors that read the response. They are
/// the same functions with their comments; only their owner changed.
enum LlamaServerChatResponse {
  /// The half of a successful parse both models agree on, so neither can lose
  /// it independently.
  ///
  /// `finish_reason == "length"` means generation STOPPED at the cap and the
  /// content is a PARTIAL rewrite. Accepting it pastes a truncated polish.
  /// Measured on the shipped binary (#2649): a 3,133-token prompt that FITS the
  /// window came back HTTP 200 with `finish_reason: length` and 21,583
  /// characters of runaway text, so this is reachable rather than theoretical,
  /// and reading the status alone would paste it as a success.
  static func truncationGuard(_ json: [String: Any]?) throws {
    if let finish = (json?["choices"] as? [[String: Any]])?.first?["finish_reason"] as? String,
      finish == "length"
    {
      throw LLMError.egOneSkipped(.outputTruncated)
    }
  }

  /// Pulls the assistant content out of a chat-completions body, or nil when the
  /// body is malformed. Emptiness is NOT decided here: the two models disagree
  /// about what an empty string means, and this returns the fact rather than
  /// the verdict.
  static func content(from json: [String: Any]?) -> String? {
    guard let choices = json?["choices"] as? [[String: Any]],
      let message = choices.first?["message"] as? [String: Any],
      let content = message["content"] as? String
    else { return nil }
    return content
  }
}
