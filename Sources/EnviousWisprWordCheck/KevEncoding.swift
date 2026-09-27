import Foundation

/// What Kev's encoder needs from a tokenizer. The shipped one is Qwen's, loaded through
/// ArgmaxCore; tests supply a character-level fake.
public protocol KevTokenizing: Sendable {
  /// Plain text to ids, never adding BOS/EOS.
  func ids(for text: String) -> [Int]
  /// The id of one special token, or nil when the vocabulary lacks it.
  func id(ofToken token: String) -> Int?
}

/// One Kev question, packed the way `kev.model.encode` packs a one-question record:
/// `[state] state-text [question] instructions ([option] text [/option])... [decide]`.
/// The readout is the hidden state at `decide` and at each option's closing token.
public struct KevEncodedQuestion: Sendable, Equatable {
  public let ids: [Int]
  public let decide: Int
  /// Closing-token positions, in option order: `no` first, then `yes`.
  public let options: [Int]
}

/// Port of the request path `kev.serve` runs for a Noul question (kev 5920c5fe):
/// `kev.api.to_record` renders the state object and the two options, and `kev.model.encode`
/// frames them. Parity with the Python path is pinned by the golden records in
/// `KevEncodingParityTests` (real tokenizer, 40 questions, identical ids).
public enum KevEncoding {
  public enum EncodingError: Error, Equatable {
    case missingSpecialToken(String)
  }

  /// The state object Kev was trained on, in field order. `kev.api.render` of a flat object of
  /// strings is one `key: value` line per field.
  public static func stateText(
    listedWord: String, asWritten: String, withListedWord: String, changedFrom: String
  ) -> String {
    [
      "listed_word: \(listedWord)",
      "as_written: \(asWritten)",
      "with_listed_word: \(withListedWord)",
      "changed_from: \(changedFrom)",
    ].joined(separator: "\n")
  }

  /// `kev.api.option_text`: the option name, then its criterion after a colon.
  public static func optionTexts(_ question: KevContract.Question) -> [String] {
    ["no: \(question.no)", "yes: \(question.yes)"]
  }

  /// `kev.model.user_tokens`: caller text can never form a `<|name|>` control token, so each such
  /// run is rewritten to `<¦name¦>` before tokenizing.
  static func escapeControlTokens(_ text: String) -> String {
    text.replacing(/<\|([A-Za-z0-9_]+)\|>/) { match in "<¦\(match.1)¦>" }
  }

  public static func encode(
    state: String, question: KevContract.Question, tokens: KevContract.SpecialTokens,
    tokenizer: some KevTokenizing
  ) throws -> KevEncodedQuestion {
    func special(_ token: String) throws -> Int {
      guard let id = tokenizer.id(ofToken: token) else {
        throw EncodingError.missingSpecialToken(token)
      }
      return id
    }
    func user(_ text: String) -> [Int] { tokenizer.ids(for: escapeControlTokens(text)) }
    var ids = [try special(tokens.state)] + user(state)
    ids += [try special(tokens.question)] + user(question.instructions)
    let open = try special(tokens.optionOpen)
    let close = try special(tokens.optionClose)
    var options: [Int] = []
    for option in optionTexts(question) {
      ids += [open] + user(option) + [close]
      options.append(ids.count - 1)
    }
    ids.append(try special(tokens.decide))
    return KevEncodedQuestion(ids: ids, decide: ids.count - 1, options: options)
  }
}
