import Foundation
import Testing

@testable import EnviousWisprWordCheck

/// Kev's input framing (#3242). When this fails, the word check reads a record shaped unlike the
/// ones it was trained on and its answers drift with no error. The framing is `kev.model.encode` and
/// `kev.api.to_record` at kev 5920c5fe; parity with the Python path on real text and the real Qwen
/// tokenizer was measured on 40 golden questions (0 differing ids) in the #3242 spike.
@Suite("KevEncoding: Kev's training framing, byte for byte (#3242)", .tags(.productOutcome))
struct KevEncodingTests {
  /// One id per character, plus the five control tokens: enough to see the frame.
  struct CharTokenizer: KevTokenizing {
    static let specials = [
      "<|fim_prefix|>": 1_000_001, "<|fim_middle|>": 1_000_002, "<|box_start|>": 1_000_003,
      "<|box_end|>": 1_000_004, "<|fim_suffix|>": 1_000_005,
    ]
    func ids(for text: String) -> [Int] { text.unicodeScalars.map { Int($0.value) } }
    func id(ofToken token: String) -> Int? { Self.specials[token] }
  }

  static let tokens = KevContract.SpecialTokens(
    state: "<|fim_prefix|>", question: "<|fim_middle|>", optionOpen: "<|box_start|>",
    optionClose: "<|box_end|>", decide: "<|fim_suffix|>")
  static let question = KevContract.Question(instructions: "Q", no: "N", yes: "Y")

  @Test("the state is Kev's rendered object: one `key: value` line per field, in training order")
  func stateText() {
    #expect(
      KevEncoding.stateText(
        listedWord: "Tuist", asWritten: "Run twist now.", withListedWord: "Run Tuist now.",
        changedFrom: "twist")
        == "listed_word: Tuist\nas_written: Run twist now.\nwith_listed_word: Run Tuist now.\nchanged_from: twist")
  }

  @Test("frame: state, question, `no` then `yes` options, decide; readouts at decide and each closer")
  func frame() throws {
    let e = try KevEncoding.encode(
      state: "S", question: Self.question, tokens: Self.tokens, tokenizer: CharTokenizer())
    let s = CharTokenizer.specials
    let expected: [Int] =
      [s["<|fim_prefix|>"]!, 83, s["<|fim_middle|>"]!, 81]
      + [s["<|box_start|>"]!] + Array("no: N".unicodeScalars.map { Int($0.value) }) + [s["<|box_end|>"]!]
      + [s["<|box_start|>"]!] + Array("yes: Y".unicodeScalars.map { Int($0.value) }) + [s["<|box_end|>"]!]
      + [s["<|fim_suffix|>"]!]
    #expect(e.ids == expected)
    #expect(e.decide == expected.count - 1)
    #expect(e.options == [4 + 1 + 5, 4 + 1 + 5 + 1 + 1 + 6])
    #expect(e.options.map { e.ids[$0] } == [s["<|box_end|>"]!, s["<|box_end|>"]!])
  }

  @Test("dictated text can never forge a control token")
  func escapesControlTokens() throws {
    let e = try KevEncoding.encode(
      state: "a <|fim_suffix|> b", question: Self.question, tokens: Self.tokens,
      tokenizer: CharTokenizer())
    // Exactly one decide token, and it is the last one.
    #expect(e.ids.filter { $0 == CharTokenizer.specials["<|fim_suffix|>"]! }.count == 1)
    #expect(KevEncoding.escapeControlTokens("x <|im_end|> y") == "x <¦im_end¦> y")
    #expect(KevEncoding.escapeControlTokens("plain <|not a token> text") == "plain <|not a token> text")
  }

  @Test("a vocabulary missing a control token refuses to encode")
  func missingSpecial() {
    struct Bare: KevTokenizing {
      func ids(for text: String) -> [Int] { [] }
      func id(ofToken token: String) -> Int? { nil }
    }
    #expect(throws: KevEncoding.EncodingError.missingSpecialToken("<|fim_prefix|>")) {
      try KevEncoding.encode(state: "S", question: Self.question, tokens: Self.tokens, tokenizer: Bare())
    }
  }
}
