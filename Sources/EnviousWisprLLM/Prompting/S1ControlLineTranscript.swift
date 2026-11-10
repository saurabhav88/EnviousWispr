import Foundation

/// The transcript inside an S1-mini user message (#4473).
///
/// This lived on `S1MiniConnector`, and `OllamaConnector` called it there, so the LLM module
/// reached into one engine's connector for a rule about the PROMPT FORMAT. Both the bundled
/// connector and Ollama send the same control-line format, so the rule sits with the prompt
/// builders. It is the same function with its comment; only its owner changed.
package enum S1ControlLineTranscript {
  /// The transcript this request carried, recovered from the user message.
  ///
  /// The empty-answer rule needs the INPUT, and the user message is
  /// `controlLine + "\n" + transcript` by construction
  /// (`S1ControlLinePromptBuilder`). Dropping the first line recovers it without
  /// threading a second parameter through the transport, which would have made
  /// the shared path know about one model's prompt shape.
  ///
  /// If the shape is ever not what this expects, the WHOLE user message is used
  /// instead. That fails toward `unexpectedEmpty`, which is the safe direction:
  /// the control line contains ordinary words, so a malformed message can only
  /// ever make an empty answer look like a failure, never like a valid empty.
  package static func transcript(fromUserMessage message: String) -> String {
    guard let newline = message.firstIndex(of: "\n"),
      message[message.startIndex..<newline].hasPrefix("[Styling:")
    else { return message }
    return String(message[message.index(after: newline)...])
  }
}
