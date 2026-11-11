import Foundation

/// The chat templates this engine can render, each known by the SHA-256 of its
/// `chat_template.jinja`. The engine has no template interpreter: it writes the two-turn prompt
/// of a known template by hand, and a model folder with any other template is refused.
package enum EnviousDecodeChatTemplate: Equatable, Sendable {
  /// System and user content exactly as given; the prompt ends with the assistant header.
  case plainAssistant
  /// As `plainAssistant`, then an empty think block. This template trims both contents, so a
  /// request whose content begins or ends with whitespace is refused instead of being trimmed
  /// here by a rule that might not be the template's.
  case emptyThinkBlock

  /// SHA-256 (lowercase hex) of the template file of each known template. Measured 2026-11-10
  /// on the candidate model folders: the first is the full-size and Mini template, the second
  /// is the Micro template.
  package static let plainAssistantSHA256 =
    "64f85b198065d0fba2a81f37e10ed68161ce2c19a754c7100e67e0ca2ee9c326"
  package static let emptyThinkBlockSHA256 =
    "273d8e0e683b885071fb17e08d71e5f2a5ddfb5309756181681de4f5a1822d80"

  package init?(templateSHA256: String) {
    switch templateSHA256.lowercased() {
    case Self.plainAssistantSHA256: self = .plainAssistant
    case Self.emptyThinkBlockSHA256: self = .emptyThinkBlock
    default: return nil
    }
  }

  static let systemHeader = "<|im_start|>system\n"
  static let userHeader = "<|im_end|>\n<|im_start|>user\n"
  static let assistantHeader = "<|im_end|>\n<|im_start|>assistant\n"
  static let emptyThink = "<think>\n\n</think>\n\n"

  /// What follows the user content.
  var tail: String {
    switch self {
    case .plainAssistant: Self.assistantHeader
    case .emptyThinkBlock: Self.assistantHeader + Self.emptyThink
    }
  }
}

/// The tokenizer, as two functions. The kit holds no tokenizer of its own; the helper gives it
/// the model folder's tokenizer.
package struct EnviousDecodeTokenizer: Sendable {
  /// Text to ids with no begin or end token added. Control tokens written in the text
  /// (`<|im_start|>`) become their ids.
  package let encode: @Sendable (String) -> [Int]
  /// Ids to text, control tokens included.
  package let decode: @Sendable ([Int]) -> String

  package init(
    encode: @escaping @Sendable (String) -> [Int], decode: @escaping @Sendable ([Int]) -> String
  ) {
    self.encode = encode
    self.decode = decode
  }
}

/// Why a model folder cannot serve requests. Nothing is guessed in its place.
package enum EnviousDecodeConfigurationError: Error, Equatable, Sendable {
  case unknownChatTemplate(sha256: String)
  /// The tokenizer has no id for a token the engine must stop on.
  case missingStopToken(String)
  case invalidContextSize(Int)
}

/// The fixed facts of one loaded model that a request is prepared against.
package struct EnviousDecodeRequestConfiguration: Equatable, Sendable {
  /// The tokens that end an answer: end of turn, then end of text. Both are required.
  package static let stopTokens = ["<|im_end|>", "<|endoftext|>"]

  /// The name a request must ask for.
  package let modelName: String
  package let template: EnviousDecodeChatTemplate
  /// Ids of `stopTokens`, in that order.
  package let stopTokenIDs: [Int]
  /// The most tokens a prompt and its answer may have together.
  package let contextTokens: Int
  /// The fixed start of a polish request's user content. When the user content starts with it,
  /// the instruction prefix runs to its end; otherwise the prefix ends before the user content.
  package let instructionOpening: String

  /// - Parameter tokenID: the id of one token by its text, or nil when the tokenizer lacks it.
  package init(
    modelName: String, templateSHA256: String, contextTokens: Int,
    instructionOpening: String = "<TRANSCRIPT>\n", tokenID: (String) -> Int?
  ) throws {
    guard let template = EnviousDecodeChatTemplate(templateSHA256: templateSHA256) else {
      throw EnviousDecodeConfigurationError.unknownChatTemplate(sha256: templateSHA256)
    }
    guard contextTokens > 0 else {
      throw EnviousDecodeConfigurationError.invalidContextSize(contextTokens)
    }
    self.modelName = modelName
    self.template = template
    self.contextTokens = contextTokens
    self.instructionOpening = instructionOpening
    self.stopTokenIDs = try Self.stopTokens.map { token in
      guard let id = tokenID(token) else {
        throw EnviousDecodeConfigurationError.missingStopToken(token)
      }
      return id
    }
  }
}

/// A request, ready for `EnviousDecodeSession.generate`.
package struct EnviousDecodePreparedRequest: Equatable, Sendable {
  package let promptTokenIDs: [Int]
  /// The prompt's leading tokens that are the instruction text, or nil when the request has no
  /// usable prefix (see `EnviousDecodeRequestMapper.prepare`). nil means a cold request.
  package let instructionPrefixTokenIDs: [Int]?
  package let maxNewTokens: Int
  package let stopTokenIDs: [Int]
}

/// Why a request body is refused. The request does not run.
package enum EnviousDecodeRequestError: Error, Equatable, Sendable {
  /// Not a JSON object, or a required field is missing or has the wrong type.
  case malformed(String)
  /// A field or value this engine does not serve. It is never ignored.
  case unsupported(field: String, reason: String)
  case wrongModel(requested: String, selected: String)
  /// The prompt alone leaves no room for an answer in the model's context.
  case contextExceeded(promptTokens: Int, contextTokens: Int)

  /// The `error.type` an HTTP answer carries. The app re-plans on `exceed_context_size_error`.
  package var errorType: String {
    switch self {
    case .contextExceeded: "exceed_context_size_error"
    case .malformed, .unsupported, .wrongModel: "invalid_request_error"
    }
  }

  package var message: String {
    switch self {
    case .malformed(let what): "malformed request: \(what)"
    case .unsupported(let field, let reason): "unsupported \(field): \(reason)"
    case .wrongModel(let requested, let selected):
      "model \(requested) is not the loaded model \(selected)"
    case .contextExceeded(let promptTokens, let contextTokens):
      "request (\(promptTokens) tokens) exceeds the available context size (\(contextTokens) tokens)"
    }
  }
}

/// Turns the app's chat request into token ids for the session, and the session's tokens back
/// into the app's answer. Pure: it owns no model and no tokenizer.
///
/// It serves exactly the request the app sends for polish and for a summary: `model`,
/// `messages` (one system turn, one user turn, text contents), `max_tokens`, `temperature` 0
/// and, optionally, `stream` false. Decoding is greedy, so any other sampling setting, a
/// streamed answer, or a field it does not know is refused, never ignored.
package enum EnviousDecodeRequestMapper {
  static let knownFields: Set<String> = [
    "model", "messages", "max_tokens", "temperature", "stream",
  ]

  package static func prepare(
    body: Data, configuration: EnviousDecodeRequestConfiguration,
    tokenizer: EnviousDecodeTokenizer
  ) throws -> EnviousDecodePreparedRequest {
    guard let json = try? JSONSerialization.jsonObject(with: body),
      let object = json as? [String: Any]
    else { throw EnviousDecodeRequestError.malformed("the body is not a JSON object") }
    for field in object.keys.sorted() where !knownFields.contains(field) {
      throw EnviousDecodeRequestError.unsupported(field: field, reason: "not served")
    }

    guard let model = object["model"] as? String else {
      throw EnviousDecodeRequestError.malformed("model must be a string")
    }
    guard model == configuration.modelName else {
      throw EnviousDecodeRequestError.wrongModel(
        requested: model, selected: configuration.modelName)
    }
    let maxTokens = try integer(object["max_tokens"], field: "max_tokens")
    guard maxTokens > 0 else {
      throw EnviousDecodeRequestError.unsupported(
        field: "max_tokens", reason: "must be above zero")
    }
    if let temperature = object["temperature"] {
      guard let value = number(temperature) else {
        throw EnviousDecodeRequestError.malformed("temperature must be a number")
      }
      guard value == 0 else {
        throw EnviousDecodeRequestError.unsupported(
          field: "temperature", reason: "decoding is greedy; only 0 is served")
      }
    }
    if let stream = object["stream"] {
      guard let value = boolean(stream) else {
        throw EnviousDecodeRequestError.malformed("stream must be true or false")
      }
      guard !value else {
        throw EnviousDecodeRequestError.unsupported(
          field: "stream", reason: "streamed answers are not served")
      }
    }
    let (system, user) = try turns(object["messages"], template: configuration.template)

    // The prompt, piece by piece. The frame pieces hold the template's control tokens; the two
    // contents are the app's text, encoded so that nothing in them becomes a control token.
    let prefixIDs =
      tokenizer.encode(EnviousDecodeChatTemplate.systemHeader)
      + contentIDs(system, tokenizer)
      + tokenizer.encode(EnviousDecodeChatTemplate.userHeader)
    let promptIDs =
      prefixIDs + contentIDs(user, tokenizer) + tokenizer.encode(configuration.template.tail)

    guard promptIDs.count < configuration.contextTokens else {
      throw EnviousDecodeRequestError.contextExceeded(
        promptTokens: promptIDs.count, contextTokens: configuration.contextTokens)
    }
    return EnviousDecodePreparedRequest(
      promptTokenIDs: promptIDs,
      instructionPrefixTokenIDs: instructionPrefix(
        frame: prefixIDs, user: user, prompt: promptIDs, configuration: configuration,
        tokenizer: tokenizer),
      // An answer cannot pass the end of the context: there the run ends as a `length` finish.
      maxNewTokens: min(maxTokens, configuration.contextTokens - promptIDs.count),
      stopTokenIDs: configuration.stopTokenIDs)
  }

  /// The instruction prefix: everything before the user's own text. When the user content
  /// starts with the configured opening (the transcript tag of a polish request), the opening
  /// belongs to the prefix. The prefix must be a true token prefix of the prompt and shorter
  /// than it; where the tokenizer joins the opening with the text after it, the prefix ends
  /// before the user content instead. A prefix is only a way to skip work, never a change of
  /// the prompt.
  static func instructionPrefix(
    frame: [Int], user: String, prompt: [Int],
    configuration: EnviousDecodeRequestConfiguration, tokenizer: EnviousDecodeTokenizer
  ) -> [Int]? {
    let opening = configuration.instructionOpening
    if !opening.isEmpty, user.hasPrefix(opening) {
      let withOpening = frame + contentIDs(opening, tokenizer)
      if withOpening.count < prompt.count, prompt.starts(with: withOpening) { return withOpening }
    }
    return frame.count < prompt.count && prompt.starts(with: frame) ? frame : nil
  }

  /// The app's text as token ids. A run written like a control token (`<|im_end|>`) inside the
  /// text must stay text: a dictated, pasted or imported run must not be able to end a turn or
  /// start one. The tokenizer would read such a run as the control token, so the text is cut
  /// right after the `<` of each run and the pieces are encoded apart; the tokenizer then never
  /// sees the whole run. The decoded text is unchanged. (How the bundled llama-server treats
  /// such a run in message content was not measured; this is the engine's own rule.)
  static func contentIDs(_ text: String, _ tokenizer: EnviousDecodeTokenizer) -> [Int] {
    var ids: [Int] = []
    var piece = ""
    var rest = Substring(text)
    while let match = rest.firstMatch(of: /<\|[A-Za-z0-9_]+\|>/) {
      piece += rest[rest.startIndex..<match.range.lowerBound] + "<"
      ids += tokenizer.encode(piece)
      piece = ""
      rest = rest[rest.index(after: match.range.lowerBound)...]
    }
    piece += rest
    if !piece.isEmpty { ids += tokenizer.encode(piece) }
    return ids
  }

  /// The app's answer: `choices[0].message.content` and `finish_reason`. The text is the
  /// generated tokens without the stop token that ended them, and nothing else is removed or
  /// trimmed: an empty or padded answer is the client's to judge.
  package static func response(
    for result: EnviousDecodeResult, configuration: EnviousDecodeRequestConfiguration,
    tokenizer: EnviousDecodeTokenizer
  ) throws -> Data {
    var tokenIDs = result.tokenIDs
    if result.endedOnStopToken, let last = tokenIDs.last,
      configuration.stopTokenIDs.contains(last)
    {
      tokenIDs.removeLast()
    }
    let body: [String: Any] = [
      "object": "chat.completion",
      "model": configuration.modelName,
      "choices": [
        [
          "index": 0,
          "message": ["role": "assistant", "content": tokenizer.decode(tokenIDs)],
          "finish_reason": result.endedOnStopToken ? "stop" : "length",
        ] as [String: Any]
      ],
    ]
    return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
  }

  /// The body of an error answer: `error.type` and `error.message`.
  package static func errorBody(for error: EnviousDecodeRequestError) throws -> Data {
    try JSONSerialization.data(
      withJSONObject: ["error": ["type": error.errorType, "message": error.message]],
      options: [.sortedKeys])
  }

  // MARK: - Fields

  /// One system turn, then one user turn, both with text content.
  static func turns(
    _ value: Any?, template: EnviousDecodeChatTemplate
  ) throws -> (system: String, user: String) {
    guard let messages = value as? [[String: Any]] else {
      throw EnviousDecodeRequestError.malformed("messages must be a list of objects")
    }
    guard messages.count == 2 else {
      throw EnviousDecodeRequestError.unsupported(
        field: "messages", reason: "exactly one system turn and one user turn are served")
    }
    var contents: [String] = []
    for (message, role) in zip(messages, ["system", "user"]) {
      for field in message.keys.sorted() where field != "role" && field != "content" {
        throw EnviousDecodeRequestError.unsupported(
          field: "messages.\(field)", reason: "not served")
      }
      guard let actual = message["role"] as? String else {
        throw EnviousDecodeRequestError.malformed("a message has no role")
      }
      guard actual == role else {
        throw EnviousDecodeRequestError.unsupported(
          field: "messages", reason: "turn \(contents.count + 1) must be \(role), not \(actual)")
      }
      guard let content = message["content"] as? String else {
        throw EnviousDecodeRequestError.unsupported(
          field: "messages.content", reason: "only text content is served")
      }
      if template == .emptyThinkBlock,
        let edge = [content.first, content.last].compactMap({ $0 })
          .first(where: \.isWhitespace)
      {
        throw EnviousDecodeRequestError.unsupported(
          field: "messages.content",
          reason:
            "the \(role) text begins or ends with whitespace (\(edge.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: " "))), which this model's template would remove"
        )
      }
      contents.append(content)
    }
    return (contents[0], contents[1])
  }

  /// A whole number, not a Boolean and not a fraction.
  static func integer(_ value: Any?, field: String) throws -> Int {
    guard let value, let number = number(value), let whole = Int(exactly: number) else {
      throw EnviousDecodeRequestError.malformed("\(field) must be a whole number")
    }
    return whole
  }

  /// A JSON number. `JSONSerialization` gives Booleans as numbers too; they are not numbers here.
  static func number(_ value: Any) -> Double? {
    guard let number = value as? NSNumber, boolean(value) == nil else { return nil }
    return number.doubleValue
  }

  static func boolean(_ value: Any) -> Bool? {
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
      return nil
    }
    return number.boolValue
  }
}
