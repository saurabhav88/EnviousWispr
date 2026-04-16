/// Role for a message in a prompt envelope.
public enum PromptRole: String, Sendable {
  case system
  case user
  case assistant
}

/// A single message in a prompt envelope.
public struct PromptMessage: Sendable {
  public let role: PromptRole
  public let content: String

  public init(role: PromptRole, content: String) {
    self.role = role
    self.content = content
  }
}

/// A structured prompt ready for a connector to map to its API format.
/// Supports system + user (single-turn) and system + user/assistant pairs (few-shot).
public struct PromptEnvelope: Sendable {
  public let messages: [PromptMessage]

  public init(messages: [PromptMessage]) {
    self.messages = messages
  }
}

extension PromptEnvelope {
  /// Extract single-turn (system, user) pair.
  /// Returns nil if envelope contains few-shot examples or multiple user turns.
  public func asSingleTurn() -> (system: String?, user: String)? {
    let systemMsgs = messages.filter { $0.role == .system }
    let userMsgs = messages.filter { $0.role == .user }
    let assistantMsgs = messages.filter { $0.role == .assistant }
    guard userMsgs.count == 1, assistantMsgs.isEmpty else { return nil }
    return (system: systemMsgs.first?.content, user: userMsgs[0].content)
  }
}
