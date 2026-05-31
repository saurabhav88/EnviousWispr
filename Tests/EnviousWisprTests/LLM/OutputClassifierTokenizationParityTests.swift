import ArgmaxOSS
import Foundation
import Testing

@testable import EnviousWisprLLM

/// THE load-bearing gate: the Swift `PairEncodingAdapter` (real Argmax tokenizer
/// + shipped contract) must reproduce the Python `PairDataset` tokenization
/// byte-for-byte. Compares against the committed golden fixture generated from
/// the canonical Python helper. If the tokenizer dependency or the encoder logic
/// drifts, this fails — preventing a silently-wrong classifier from shipping.
@Suite struct OutputClassifierTokenizationParityTests {

  private struct SourceRow: Decodable {
    let id: String
    let input: String
    let output: String
  }
  private struct PretokRow: Decodable {
    let id: String
    let input_ids: [Int]
    let attention_mask: [Int]
    let token_type_ids: [Int]
  }

  private func loadJSONL<T: Decodable>(_ url: URL, as: T.Type) throws -> [T] {
    let text = try String(contentsOf: url, encoding: .utf8)
    let decoder = JSONDecoder()
    return try text.split(separator: "\n").compactMap { line in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty else { return nil }
      return try decoder.decode(T.self, from: Data(trimmed.utf8))
    }
  }

  @Test("Swift tokenization matches the Python golden fixture byte-for-byte (50 rows)")
  func byteForByteParity() async throws {
    let contract = try TokenizerContract.load(from: OutputClassifierTestPaths.contract)
    let tokenizer = try await AutoTokenizerWrapper.from(
      modelFolder: OutputClassifierTestPaths.tokenizerFolder, strict: true)
    let adapter = PairEncodingAdapter(contract: contract) { text in
      tokenizer.encode(text: text, addSpecialTokens: false)
    }

    let sources = try loadJSONL(OutputClassifierTestPaths.paritySource, as: SourceRow.self)
    let golden = try loadJSONL(OutputClassifierTestPaths.pretokenizedFixture, as: PretokRow.self)
    let goldenByID = Dictionary(uniqueKeysWithValues: golden.map { ($0.id, $0) })

    #expect(sources.count == 50)
    #expect(golden.count == 50)

    var compared = 0
    for source in sources {
      guard let expected = goldenByID[source.id] else {
        Issue.record("no golden row for id \(source.id)")
        continue
      }
      let encoded = adapter.encodePair(input: source.input, output: source.output)
      #expect(
        encoded.inputIDs == expected.input_ids.map(Int32.init),
        "input_ids mismatch for id \(source.id)")
      #expect(
        encoded.attentionMask == expected.attention_mask.map(Int32.init),
        "attention_mask mismatch for id \(source.id)")
      #expect(
        encoded.tokenTypeIDs == expected.token_type_ids.map(Int32.init),
        "token_type_ids mismatch for id \(source.id)")
      // Shape lock.
      #expect(encoded.inputIDs.count == 128)
      #expect(encoded.attentionMask.count == 128)
      #expect(encoded.tokenTypeIDs.count == 128)
      compared += 1
    }
    #expect(compared == 50)
  }
}
