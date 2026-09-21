import ArgmaxOSS
import Foundation

/// Benchmark-only door for the edit-judge compatibility probe (#996 chunk
/// 2b): the eval runner (`scripts/eval/alias_runner`) asks the SHIPPED
/// tokenizer stack to encode texts and pairs exactly as a production
/// cross-encoder would, so Python can compare the ids against the reference
/// tokenizer before any model is trained. JSON in, JSON out: the runner
/// package never sees production types. Nothing production calls this.
///
/// Request:
/// `{"tokenizer_folder":"/abs/dir","texts":["…"],"contract":"/abs/contract.json"?,
///   "pairs":[{"input":"…","output":"…"}]?}`
/// Response:
/// `{"loaded":true,"texts":[{"text":"…","ids":[…]}],"pairs":[{"input_ids":[…],
///   "attention_mask":[…],"token_type_ids":[…]}]?,"contract_error":"…"?}`
/// or `{"loaded":false,"error":"…"}` when the tokenizer refuses to load
/// (strict mode: an unregistered tokenizer class is a load FAILURE, never a
/// silent fallback to another implementation).
// periphery:ignore - eval harness API (scripts/eval/alias_runner)
public enum CorrectionJudgeBenchmark {
  /// The same pair assembly `tokenizerParity` performs, with the caller's
  /// encode function instead of the vendored tokenizer (#996 chunk 4a-ii):
  /// the eval runner passes its pinned upstream tokenizer so the SHIPPED
  /// `PairEncodingAdapter` (specials, truncation, padding) is what Python
  /// checks for parity, never a copy of it. Throws when the contract fails
  /// to load or validate. Nothing production calls this.
  public static func encodePairs(
    contractJSON: Data, pairs: [(input: String, output: String)],
    encode: @escaping @Sendable (String) -> [Int]
  ) throws -> [EncodedClassifierInput] {
    // Bytes, not a path: the caller verifies the contract's digest once and
    // keeps the verified bytes, so a later edit of the file cannot change the
    // encoding under the old identity.
    let contract = try JSONDecoder().decode(TokenizerContract.self, from: contractJSON)
    let adapter = PairEncodingAdapter(contract: contract, encode: encode)
    try adapter.validate()
    return pairs.map { adapter.encodePair(input: $0.input, output: $0.output) }
  }

  public static func tokenizerParity(requestJSON: Data) async -> Data {
    struct Pair: Decodable {
      let input: String
      let output: String
    }
    struct Request: Decodable {
      let tokenizer_folder: String
      let texts: [String]
      let contract: String?
      let pairs: [Pair]?
    }
    struct EncodedText: Encodable {
      let text: String
      let ids: [Int]
    }
    struct EncodedPair: Encodable {
      let input_ids: [Int32]
      let attention_mask: [Int32]
      let token_type_ids: [Int32]
    }
    struct Response: Encodable {
      let loaded: Bool
      let error: String?
      let texts: [EncodedText]?
      let pairs: [EncodedPair]?
      let contract_error: String?
      let special_tokens: [String: Int]?
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    func emit(_ r: Response) -> Data { (try? encoder.encode(r)) ?? Data() }

    let request: Request
    do {
      request = try JSONDecoder().decode(Request.self, from: requestJSON)
    } catch {
      return emit(
        Response(
          loaded: false, error: "request rejected: \(error)", texts: nil, pairs: nil,
          contract_error: nil, special_tokens: nil))
    }
    let folder = URL(fileURLWithPath: request.tokenizer_folder, isDirectory: true)
    let tokenizer: TokenizerWrapper
    do {
      // The same call `CoreMLOutputClassifier.load` makes: strict, local folder.
      tokenizer = try await AutoTokenizerWrapper.from(modelFolder: folder, strict: true)
    } catch {
      return emit(
        Response(
          loaded: false, error: "tokenizer load failed (strict): \(error)", texts: nil, pairs: nil,
          contract_error: nil, special_tokens: nil))
    }
    let texts = request.texts.map {
      EncodedText(text: $0, ids: tokenizer.encode(text: $0, addSpecialTokens: false))
    }
    var specials: [String: Int] = [:]
    for name in [
      "<s>", "</s>", "<pad>", "[CLS]", "[SEP]", "[PAD]", "<bos>", "<eos>", "<unk>", "[UNK]",
    ] {
      if let id = tokenizer.convertTokenToId(name) { specials[name] = id }
    }

    var pairs: [EncodedPair]? = nil
    var contractError: String? = nil
    if let contractPath = request.contract, let pairInputs = request.pairs {
      do {
        let contract = try TokenizerContract.load(from: URL(fileURLWithPath: contractPath))
        let adapter = PairEncodingAdapter(contract: contract) { text in
          tokenizer.encode(text: text, addSpecialTokens: false)
        }
        try adapter.validate()
        pairs = pairInputs.map { p in
          let e = adapter.encodePair(input: p.input, output: p.output)
          return EncodedPair(
            input_ids: e.inputIDs, attention_mask: e.attentionMask, token_type_ids: e.tokenTypeIDs)
        }
      } catch {
        contractError = "contract rejected: \(error)"
      }
    }
    return emit(
      Response(
        loaded: true, error: nil, texts: texts, pairs: pairs, contract_error: contractError,
        special_tokens: specials))
  }
}
