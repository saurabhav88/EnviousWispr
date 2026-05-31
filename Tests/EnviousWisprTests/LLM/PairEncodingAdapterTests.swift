import Foundation
import Testing

@testable import EnviousWisprLLM

/// Deterministic pair-encoder math (no real tokenizer/model). The real
/// byte-for-byte parity gate is `OutputClassifierTokenizationParityTests`; these
/// isolate the truncation/assembly/segment/padding logic with a controllable
/// word-index tokenizer and prove the seam is config-driven (BERT + RoBERTa).
@Suite struct PairEncodingAdapterTests {

  private func bertAdapter() throws -> PairEncodingAdapter {
    let contract = try TokenizerContract.load(from: OutputClassifierTestPaths.contract)
    return PairEncodingAdapter(contract: contract, encode: wordIndexEncoder)
  }

  @Test("BERT assembly: [CLS] in [SEP] out [SEP], segments 0/1, mask, pad to 128")
  func bertBasicAssembly() throws {
    let adapter = try bertAdapter()
    let encoded = adapter.encodePair(input: "a b", output: "x y z")
    // "Input: a b" → 3 word-ids; "Output: x y z" → 4 word-ids.
    let expectedHead: [Int32] = [101, 1000, 1001, 1002, 102, 1000, 1001, 1002, 1003, 102]
    #expect(Array(encoded.inputIDs.prefix(10)) == expectedHead)
    #expect(encoded.inputIDs.count == 128)
    #expect(encoded.attentionMask.count == 128)
    #expect(encoded.tokenTypeIDs.count == 128)
    // 10 real tokens, rest padding.
    #expect(encoded.attentionMask.prefix(10).allSatisfy { $0 == 1 })
    #expect(encoded.attentionMask.dropFirst(10).allSatisfy { $0 == 0 })
    #expect(encoded.inputIDs.dropFirst(10).allSatisfy { $0 == 0 })
    // segments: 0 for [CLS]+in+[SEP] (5), 1 for out+[SEP] (5), 0 for pad.
    #expect(Array(encoded.tokenTypeIDs.prefix(10)) == [0, 0, 0, 0, 0, 1, 1, 1, 1, 1])
    #expect(encoded.tokenTypeIDs.dropFirst(10).allSatisfy { $0 == 0 })
  }

  @Test("empty input and output still produce valid specials + segments")
  func emptyPair() throws {
    let adapter = try bertAdapter()
    let encoded = adapter.encodePair(input: "", output: "")
    // "Input: " → 1 word-id; "Output: " → 1 word-id.
    #expect(Array(encoded.inputIDs.prefix(5)) == [101, 1000, 102, 1000, 102])
    #expect(Array(encoded.tokenTypeIDs.prefix(5)) == [0, 0, 0, 1, 1])
    #expect(encoded.attentionMask.prefix(5).allSatisfy { $0 == 1 })
    #expect(encoded.inputIDs.count == 128)
  }

  @Test("long input gets head+tail truncation to 92 tokens (head 60, tail 32)")
  func inputHeadTailTruncation() throws {
    let adapter = try bertAdapter()
    // "Input: " + 100 words → 101 word-ids (> cap 92). head=min(64,92-32)=60, tail=32.
    let input = (1...100).map { "w\($0)" }.joined(separator: " ")
    // 50-word output → 51 ids (> budget 32) → tail-truncated to 32.
    let output = (1...50).map { "o\($0)" }.joined(separator: " ")
    let encoded = adapter.encodePair(input: input, output: output)

    // Real tokens = [CLS] + 92 in + [SEP] + 32 out + [SEP] = 127; 1 pad.
    let realCount = encoded.attentionMask.filter { $0 == 1 }.count
    #expect(realCount == 127)
    #expect(encoded.attentionMask.last == 0)
    // Input portion is ids[1..92]; first 60 are the head (1000..1059), then the
    // tail jumps to the last 32 of the original 101 (1069..1100).
    #expect(encoded.inputIDs[1] == 1000)
    #expect(encoded.inputIDs[60] == 1059)
    #expect(encoded.inputIDs[61] == 1069)  // head/tail seam
    #expect(encoded.inputIDs[92] == 1100)
    #expect(encoded.inputIDs[93] == 102)  // [SEP] after input
  }

  @Test("output exceeding budget is tail-truncated; boundary budget == minOutputTokens")
  func outputTailTruncation() throws {
    let adapter = try bertAdapter()
    let input = "short input here"  // small → budget stays large
    let output = (1...200).map { "o\($0)" }.joined(separator: " ")
    let encoded = adapter.encodePair(input: input, output: output)
    #expect(encoded.inputIDs.count == 128)
    // total real ≤ 128, last token is [SEP], output was truncated (not all 201 ids).
    let realCount = encoded.attentionMask.filter { $0 == 1 }.count
    #expect(realCount <= 128)
    #expect(realCount > 32)
  }

  @Test("RoBERTa contract drives <s> A </s></s> B </s> with no segment flip — config only")
  func robertaConfigDriven() throws {
    let json = """
      {
        "contractVersion": 1, "modelName": "roberta-example", "family": "roberta_bpe",
        "inputPrefix": "Input: ", "outputPrefix": "Output: ",
        "pairTemplate": { "kind": "roberta_pair",
          "sequence": ["bos","input","eos","eos","output","eos"] },
        "specialTokenIds": { "pad": 1, "bos": 0, "eos": 2 },
        "specialsBudget": 4, "maxLength": 128, "minOutputTokens": 32,
        "inputTruncationPolicy": { "kind": "head_tail", "headTokens": 64, "tailTokens": 32 },
        "outputTruncationPolicy": { "kind": "tail", "headTokens": 64, "tailTokens": 32 },
        "tokenTypePolicy": { "kind": "none", "needsSegmentIds": false, "segmentVocabSize": 1 }
      }
      """
    let contract = try decodeContract(json)
    let adapter = PairEncodingAdapter(contract: contract, encode: wordIndexEncoder)
    try adapter.validate()
    let encoded = adapter.encodePair(input: "a", output: "b")
    // "Input: a" → [1000,1001]; "Output: b" → [1000,1001].
    // <s> in </s></s> out </s> = [0,1000,1001,2,2,1000,1001,2]
    #expect(Array(encoded.inputIDs.prefix(8)) == [0, 1000, 1001, 2, 2, 1000, 1001, 2])
    // No segment flip for roberta — all pad-segment (0).
    #expect(encoded.tokenTypeIDs.prefix(8).allSatisfy { $0 == 0 })
    // Right-padded with pad id 1.
    #expect(encoded.inputIDs.dropFirst(8).allSatisfy { $0 == 1 })
  }

  // Contract whose specials all resolve (cls/sep/pad present) but which declares
  // an unknown kind in one slot — validate() must still reject it (Codex P2).
  private func contractWithOverride(_ overrides: [String: String]) -> String {
    func v(_ key: String, _ dflt: String) -> String { overrides[key] ?? dflt }
    return """
      {
        "contractVersion": 1, "modelName": "x", "family": "\(v("family", "bert_wordpiece"))",
        "inputPrefix": "Input: ", "outputPrefix": "Output: ",
        "pairTemplate": { "kind": "\(v("templateKind", "bert_pair"))", "sequence": ["cls","input","sep","output","sep"] },
        "specialTokenIds": { "pad": 0, "cls": 101, "sep": 102 },
        "specialsBudget": \(v("specialsBudget", "4")), "maxLength": \(v("maxLength", "128")),
        "minOutputTokens": 32,
        "inputTruncationPolicy": { "kind": "head_tail", "headTokens": 64, "tailTokens": 32 },
        "outputTruncationPolicy": { "kind": "\(v("outTrunc", "tail"))", "headTokens": 64, "tailTokens": 32 },
        "tokenTypePolicy": { "kind": "\(v("ttKind", "bert_segments"))", "needsSegmentIds": true, "segmentVocabSize": 2 }
      }
      """
  }

  @Test(
    "validate() rejects unsupported family / template / token-type / truncation / maxLength",
    arguments: [
      ["family": "deberta_v3"],
      ["templateKind": "deberta_pair"],
      ["ttKind": "deberta_segments"],
      ["outTrunc": "middle"],
      ["maxLength": "10"],  // <= specialsBudget + minOutputTokens
      ["specialsBudget": "0"],
    ])
  func validateRejectsUnsupported(_ override: [String: String]) throws {
    let adapter = PairEncodingAdapter(
      contract: try decodeContract(contractWithOverride(override)), encode: wordIndexEncoder)
    #expect(throws: OutputClassifierError.self) { try adapter.validate() }
  }

  @Test("validate() accepts the shipped contract + a well-formed RoBERTa contract")
  func validateAcceptsSupported() throws {
    let bert = try TokenizerContract.load(from: OutputClassifierTestPaths.contract)
    try PairEncodingAdapter(contract: bert, encode: wordIndexEncoder).validate()
  }

  @Test("validate() throws unsupportedFamily when a template special is missing")
  func validateMissingSpecial() throws {
    let json = """
      {
        "contractVersion": 1, "modelName": "bad", "family": "bert_wordpiece",
        "inputPrefix": "Input: ", "outputPrefix": "Output: ",
        "pairTemplate": { "kind": "bert_pair", "sequence": ["cls","input","sep","output","sep"] },
        "specialTokenIds": { "pad": 0 },
        "specialsBudget": 4, "maxLength": 128, "minOutputTokens": 32,
        "inputTruncationPolicy": { "kind": "head_tail", "headTokens": 64, "tailTokens": 32 },
        "outputTruncationPolicy": { "kind": "tail", "headTokens": 64, "tailTokens": 32 },
        "tokenTypePolicy": { "kind": "bert_segments", "needsSegmentIds": true, "segmentVocabSize": 2 }
      }
      """
    let adapter = PairEncodingAdapter(contract: try decodeContract(json), encode: wordIndexEncoder)
    #expect(throws: OutputClassifierError.self) { try adapter.validate() }
  }
}
