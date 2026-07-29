import ArgmaxOSS
import CoreML
import Foundation
import Testing

@testable import EnviousWisprLLM

/// Pins what the classifier ACTUALLY RETURNS, not just that it loads.
///
/// `OutputClassifierTokenizationParityTests` proves Swift tokenizes identically
/// to Python, and `OutputClassifierContractTests` pins the model file's bytes.
/// Neither checks that the model turns those tokens into the right scores, so
/// before #1226 a model swap that changed every decision passed the whole suite.
/// The `MiniLM-L6.golden-scores.jsonl` fixture had existed since PR8 and was
/// asserted against nowhere. This is the test that uses it.
///
/// Scores are read through the product API (`CoreMLOutputClassifier.score`), so
/// a regression anywhere in load, tokenize, feature-build, or inference fails
/// here rather than only in a bespoke probe.
///
/// SCOPE LIMIT, deliberate. This loads the committed source `.mlpackage` through
/// the product API, under the app's own `.cpuAndNeuralEngine` policy. What SHIPS
/// is `OutputClassifier.mlmodelc`, compiled by Xcode's build rule — still a
/// different artifact, and Core ML's physical placement within that policy is
/// its own business. That combination is exactly where #1226 hid, and it is
/// covered by `scripts/uat/probe-classifier-compute-units.swift`, which asserts
/// this same fixture against the built bundle on all four compute-unit policies.
/// Run it after any model change; this suite alone does not cover the shipped path.
///
/// Regenerate the fixtures with `scripts/emit-output-classifier-golden.py`
/// whenever the shipped `.mlpackage` changes.
@Suite struct OutputClassifierGoldenScoreTests {

  /// Probability tolerance, justified from measurement in both directions
  /// (#1226, measured on Mac16,8 across all four Core ML compute units):
  ///   * LOOSE enough: the worst cross-compute probability spread on 6,054 rows
  ///     was 2.65e-06, so this sits ~38x above the noise this test must tolerate.
  ///   * TIGHT enough: converting the model FLOAT16 -> FLOAT32 moved these 50
  ///     rows by up to 1.6e-04, so a precision change of that size still fails.
  /// It bounds probabilities only. The spread was measured on probabilities and
  /// says nothing about raw logits, which are not asserted here.
  ///
  /// Measured on Apple Silicon M4. Other hardware is not proven to agree this
  /// closely; if this ever fails on a new machine by a small margin, suspect the
  /// hardware assumption before suspecting the model.
  private static let probabilityTolerance = 1e-4

  private struct SourceRow: Decodable {
    let id: String
    let input: String
    let output: String
  }
  private struct GoldenRow: Decodable {
    let id: String
    let prob: Double
    let decision: String
  }
  private struct BoundaryRow: Decodable {
    let id: String
    let input: String
    let output: String
    let input_ids: [Int]
    let attention_mask: [Int]
    let token_type_ids: [Int]
    let prob: Double
    let margin: Double
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

  private func loadClassifier() async throws -> CoreMLOutputClassifier {
    try await CoreMLOutputClassifier.load(
      resourceURL: OutputClassifierTestPaths.repoRoot.appending(
        path: "Sources/EnviousWisprLLM/Resources"))
  }

  @Test("the product load excludes the GPU")
  func productLoadExcludesGPU() async throws {
    // The numerical tests above cannot catch a reversion to `.all`, because
    // `.all` returns the RIGHT answers — it just places the model on the GPU and
    // costs ~200 MB resident instead of ~4 MB (#1226). Nothing else in the suite
    // would notice, so the policy itself is pinned here.
    let classifier = try await loadClassifier()
    let computeUnits = await classifier.configuredComputeUnits
    #expect(computeUnits == .cpuAndNeuralEngine)
  }

  @Test("shipped model reproduces the golden scores and decisions (50 rows)")
  func goldenScoresMatch() async throws {
    let classifier = try await loadClassifier()
    let sources = try loadJSONL(OutputClassifierTestPaths.paritySource, as: SourceRow.self)
    let golden = try loadJSONL(OutputClassifierTestPaths.goldenScores, as: GoldenRow.self)

    #expect(sources.count == 50)
    #expect(golden.count == 50)
    // Counts alone are satisfied by a DUPLICATE that replaced another row: the
    // total still reads 50, `compared` below still reaches 50, and one intended
    // case is silently scored twice while another vanishes. Assert identity too.
    #expect(Set(sources.map(\.id)).count == 50, "parity source has duplicate ids")
    #expect(Set(golden.map(\.id)).count == 50, "golden fixture has duplicate ids")
    // Build the lookup only AFTER those checks: `uniqueKeysWithValues` TRAPS on a
    // repeated key, so constructing it first would abort the whole test process on
    // the exact fixture defect the expectations above exist to report clearly.
    // (Same ordering already applied in probe-classifier-compute-units.swift.)
    guard Set(golden.map(\.id)).count == golden.count else { return }
    let goldenByID = Dictionary(uniqueKeysWithValues: golden.map { ($0.id, $0) })

    var compared = 0
    for source in sources {
      guard let expected = goldenByID[source.id] else {
        Issue.record("no golden row for id \(source.id)")
        continue
      }
      let probability = try await classifier.score(input: source.input, polished: source.output)
      let delta = abs(probability - expected.prob)
      #expect(
        delta <= Self.probabilityTolerance,
        "probability drift \(delta) for id \(source.id): got \(probability), expected \(expected.prob)"
      )
      // Decision is what a user can observe, so it is pinned exactly. Every one
      // of these 50 rows sits at least 6.8e-02 from the threshold — three orders
      // of magnitude outside the tolerance above — so this cannot flake on a
      // score that merely wobbled. The generator refuses to emit a row closer
      // than 1e-3 for exactly this reason.
      let decision = probability >= OutputClassifierManifest.discardThreshold ? "DISCARD" : "KEEP"
      #expect(decision == expected.decision, "decision changed for id \(source.id)")
      compared += 1
    }
    #expect(compared == 50)
  }

  @Test("the known knife-edge row stays at the threshold, either side of it")
  func boundaryRowStaysAtTheThreshold() async throws {
    let boundary = try loadJSONL(
      OutputClassifierTestPaths.boundaryRow, as: BoundaryRow.self)
    #expect(boundary.count == 1)
    guard let row = boundary.first else { return }

    // `reformat-03718` scores ~5.5e-08 from the discard threshold — far closer
    // than the ~2.7e-06 spread between compute units, so which side it lands on
    // is genuinely undecidable and always has been: the FLOAT16 model that
    // shipped before disagreed with the PyTorch reference on this row by 4e-04,
    // and the FLOAT32 model flips it between CPU-only and the Neural Engine.
    // Asserting its DECISION would manufacture a flaky test, so this pins only
    // that it stays pinned to the threshold. A flip here is expected behaviour,
    // not a regression.

    // Tokenization is pinned separately for the 50 parity rows but not for this
    // one, so check it here. Without this, a tokenizer drift would surface as a
    // confusing score mismatch instead of naming its own cause.
    let contract = try TokenizerContract.load(from: OutputClassifierTestPaths.contract)
    let tokenizer = try await AutoTokenizerWrapper.from(
      modelFolder: OutputClassifierTestPaths.tokenizerFolder, strict: true)
    let adapter = PairEncodingAdapter(contract: contract) { text in
      tokenizer.encode(text: text, addSpecialTokens: false)
    }
    let encoded = adapter.encodePair(input: row.input, output: row.output)
    #expect(encoded.inputIDs == row.input_ids.map(Int32.init))
    #expect(encoded.attentionMask == row.attention_mask.map(Int32.init))
    #expect(encoded.tokenTypeIDs == row.token_type_ids.map(Int32.init))

    let classifier = try await loadClassifier()
    let probability = try await classifier.score(input: row.input, polished: row.output)
    let delta = abs(probability - row.prob)
    #expect(
      delta <= Self.probabilityTolerance,
      "boundary probability drift \(delta): got \(probability), expected \(row.prob)")

    // Assert the MEASURED margin, not the one recorded in the fixture — a
    // recorded value only proves the fixture is consistent with itself. If the
    // live model ever moves this row away from the threshold it is no longer a
    // knife-edge case, and this test's whole premise (and its refusal to pin a
    // decision) would silently stop applying.
    let measuredMargin = abs(probability - OutputClassifierManifest.discardThreshold)
    #expect(
      measuredMargin < 1e-6,
      "boundary row is no longer at the threshold: margin \(measuredMargin)")
  }
}
