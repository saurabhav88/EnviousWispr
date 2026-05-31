import CryptoKit
import Foundation

/// Per-model tokenizer contract that drives the config-driven pair-encoder seam
/// (`PairEncodingAdapter`). Shipped as `tokenizer-contract.json` next to the
/// tokenizer files. The same shape supports BERT/MiniLM (`bert_pair` +
/// `bert_segments`) and RoBERTa-family (`roberta_pair` + `none`) encoders so
/// future cross-encoders reuse the seam via config, not coordinator code.
public struct TokenizerContract: Codable, Sendable, Equatable {
  public struct PairTemplate: Codable, Sendable, Equatable {
    public let kind: String  // "bert_pair" | "roberta_pair"
    public let sequence: [String]  // e.g. ["cls","input","sep","output","sep"]
  }
  public struct OutputTruncationPolicy: Codable, Sendable, Equatable {
    public let kind: String  // "tail" | "head_tail"
    public let headTokens: Int
    public let tailTokens: Int
  }
  public struct TokenTypePolicy: Codable, Sendable, Equatable {
    public let kind: String  // "bert_segments" | "none"
    public let needsSegmentIds: Bool
    public let segmentVocabSize: Int
    public let inputSegmentId: Int?
    public let outputSegmentId: Int?
    public let padSegmentId: Int?
  }

  public let contractVersion: Int
  public let modelName: String
  public let family: String  // "bert_wordpiece" | "roberta_bpe"
  public let inputPrefix: String  // "Input: "
  public let outputPrefix: String  // "Output: "
  public let pairTemplate: PairTemplate
  public let specialTokenIds: [String: Int]  // pad/cls/sep (or bos/eos)
  public let specialsBudget: Int
  public let maxLength: Int
  public let minOutputTokens: Int
  public let inputTruncationPolicy: OutputTruncationPolicy  // reuse shape (head/tail)
  public let outputTruncationPolicy: OutputTruncationPolicy
  public let tokenTypePolicy: TokenTypePolicy
  public let contractHash: String?

  // MARK: - Loading

  /// Decode a contract file. Throws on malformed JSON or missing required keys.
  public static func load(from url: URL) throws -> TokenizerContract {
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(TokenizerContract.self, from: data)
  }

  // MARK: - Integrity

  /// Recompute the canonical contract hash exactly as the Python generator does:
  ///   sha256( canonical(contract WITHOUT contractHash) ++ tokenizer.json bytes
  ///           ++ tokenizer_config.json bytes )
  /// canonical = JSON with sorted keys, compact separators, UTF-8.
  /// File byte order is sorted by relative path: tokenizer.json, tokenizer_config.json.
  ///
  /// Operates on the RAW parsed JSON (not this struct) so every field present in
  /// the file participates, matching the generator regardless of which keys the
  /// Swift model happens to decode.
  public static func recomputeContractHash(
    contractURL: URL,
    tokenizerJSONURL: URL,
    tokenizerConfigURL: URL
  ) throws -> String {
    let contractData = try Data(contentsOf: contractURL)
    guard
      var object = try JSONSerialization.jsonObject(with: contractData) as? [String: Any]
    else {
      throw OutputClassifierError.disabled(.contractHashMismatch)
    }
    object.removeValue(forKey: "contractHash")
    // Custom canonical serializer (NOT JSONSerialization `.sortedKeys`): that
    // option sorts keys CASE-INSENSITIVELY (e.g. "specialsBudget" before
    // "specialTokenIds"), diverging from Python json.dumps(sort_keys=True),
    // which sorts by code point. `CanonicalJSON` sorts via Swift `String <`
    // (code-point for ASCII) + compact separators, byte-for-byte matching
    // json.dumps(sort_keys=True, separators=(',',':'), ensure_ascii=False).
    let canonical = try CanonicalJSON.encode(object)

    var combined = Data()
    combined.append(canonical)
    combined.append(try Data(contentsOf: tokenizerJSONURL))
    combined.append(try Data(contentsOf: tokenizerConfigURL))

    let digest = SHA256.hash(data: combined)
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  /// Verify the stored `contractHash` against a fresh recompute. Returns the
  /// recomputed digest on success; throws `.disabled(.contractHashMismatch)` on
  /// any mismatch or missing stored hash.
  @discardableResult
  public static func verify(
    contractURL: URL,
    tokenizerJSONURL: URL,
    tokenizerConfigURL: URL
  ) throws -> String {
    let contract = try load(from: contractURL)
    guard let stored = contract.contractHash else {
      throw OutputClassifierError.disabled(.contractHashMismatch)
    }
    let recomputed = try recomputeContractHash(
      contractURL: contractURL,
      tokenizerJSONURL: tokenizerJSONURL,
      tokenizerConfigURL: tokenizerConfigURL
    )
    guard recomputed == stored else {
      throw OutputClassifierError.disabled(.contractHashMismatch)
    }
    return recomputed
  }
}

/// Deterministic, cross-language-stable canonical JSON. Byte-for-byte matches
/// Python `json.dumps(value, sort_keys=True, separators=(',',':'), ensure_ascii=False)`:
/// keys sorted by code point (Swift `String <`), compact separators, standard
/// escaping, integers without a decimal point. Used for the tokenizer contract
/// hash so the Swift runtime verifier and the Python fixture generator agree.
/// Supports the JSON subset the contract uses: object / array / String / Bool /
/// integer NSNumber. Throws on an unsupported type (e.g. a float).
enum CanonicalJSON {
  struct UnsupportedValue: Error { let typeDescription: String }

  static func encode(_ value: Any) throws -> Data {
    var out = String()
    try append(value, to: &out)
    return Data(out.utf8)
  }

  private static func append(_ value: Any, to out: inout String) throws {
    switch value {
    case let dict as [String: Any]:
      out.append("{")
      let keys = dict.keys.sorted()  // code-point order for ASCII (matches Python)
      for (index, key) in keys.enumerated() {
        if index > 0 { out.append(",") }
        appendString(key, to: &out)
        out.append(":")
        try append(dict[key]!, to: &out)
      }
      out.append("}")
    case let array as [Any]:
      out.append("[")
      for (index, element) in array.enumerated() {
        if index > 0 { out.append(",") }
        try append(element, to: &out)
      }
      out.append("]")
    case let string as String:
      appendString(string, to: &out)
    case let number as NSNumber:
      if CFGetTypeID(number) == CFBooleanGetTypeID() {
        out.append(number.boolValue ? "true" : "false")
      } else {
        // Contract values are integers only; reject a non-integral number
        // rather than silently emitting a format Python wouldn't match.
        guard Double(number.intValue) == number.doubleValue else {
          throw UnsupportedValue(typeDescription: "non-integer number \(number)")
        }
        out.append(String(number.intValue))
      }
    case is NSNull:
      out.append("null")
    default:
      throw UnsupportedValue(typeDescription: String(describing: type(of: value)))
    }
  }

  private static func appendString(_ string: String, to out: inout String) {
    out.append("\"")
    for scalar in string.unicodeScalars {
      switch scalar {
      case "\"": out.append("\\\"")
      case "\\": out.append("\\\\")
      case "\n": out.append("\\n")
      case "\r": out.append("\\r")
      case "\t": out.append("\\t")
      case "\u{08}": out.append("\\b")
      case "\u{0C}": out.append("\\f")
      case let s where s.value < 0x20:
        out.append(String(format: "\\u%04x", s.value))
      default:
        out.unicodeScalars.append(scalar)  // raw UTF-8 (ensure_ascii=False)
      }
    }
    out.append("\"")
  }
}
