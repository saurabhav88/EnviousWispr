import Foundation
import Testing

@testable import EnviousWisprWordCheck

/// A freshly exported word-check bundle against the Python MLX path that trained and graded it
/// (#3242). `export_app_bundle.py` writes `golden.jsonl` (state text and p(true) for real exam
/// questions) next to the weights; the app must give the same answers, or the cutoff graded in
/// Python no longer means what it did. Catches a loader that reads the weights at the wrong width
/// (kev-wc-2 keeps the embedding at 4 bits and the layers at 5), a changed framing, or a head
/// mismatch. Runs only when `KEV_GOLDEN_DIR` names such a folder
/// (`TEST_RUNNER_KEV_GOLDEN_DIR=<folder> scripts/xcode-test.sh ...`); skipped everywhere else.
@Suite("Kev word check: the app answers as the Python export did (#3242)", .tags(.productOutcome))
struct KevGoldenParityTests {
  static let folder = ProcessInfo.processInfo.environment["KEV_GOLDEN_DIR"].map {
    URL(fileURLWithPath: $0, isDirectory: true)
  }
  static var goldenPresent: Bool {
    folder.map {
      FileManager.default.fileExists(atPath: $0.appendingPathComponent("golden.jsonl").path)
    }
      ?? false
  }

  struct Golden: Decodable {
    let qid: String
    let stateText: String
    /// Option probabilities in the contract's order, no then yes.
    let p: [Double]
    var yes: Double { p[1] }
    enum CodingKeys: String, CodingKey {
      case qid
      case stateText = "state_text"
      case p
    }
  }

  @Test(
    "every golden question within 0.05 and on the same side of the cutoff; mean difference under 0.005",
    .enabled(if: goldenPresent))
  func appMatchesPythonExport() async throws {
    let folder = try #require(Self.folder)
    let golden = try String(
      contentsOf: folder.appendingPathComponent("golden.jsonl"), encoding: .utf8
    )
    .split(separator: "\n").map { try JSONDecoder().decode(Golden.self, from: Data($0.utf8)) }
    #expect(golden.count >= 40)
    #expect(golden.allSatisfy { $0.p.count == 2 })
    let model = try await KevWordCheckModel(folder: folder)
    try await model.warmUp()
    let cutoff = await model.contract.threshold
    var worst = 0.0
    var total = 0.0
    for row in golden {
      let p = Double(try await model.probabilities(forStates: [row.stateText])[0])
      worst = max(worst, abs(p - row.yes))
      total += abs(p - row.yes)
      #expect(abs(p - row.yes) < 0.05, "\(row.qid): app \(p), Python \(row.yes)")
      #expect(
        (p >= cutoff) == (row.yes >= cutoff),
        "\(row.qid) crosses the cutoff: app \(p), Python \(row.yes)")
    }
    // Measured 2026-09-27 (M5 Max): kev-wc-1 worst 0.038, mean 0.0019; kev-wc-2 worst 0.022, mean
    // 0.0008. Questions near p = 0.5 move most; a wrong-width load is not a rounding error.
    #expect(total / Double(golden.count) < 0.005)
    print(
      "KevGoldenParity: \(golden.count) questions, worst difference \(worst), mean \(total / Double(golden.count))")
  }
}
