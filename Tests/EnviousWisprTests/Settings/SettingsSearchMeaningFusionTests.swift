import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #3482 chunk 3: the meaning pass re-orders the word results and adds places only the meaning
/// model found. **When this fails, the user types a sentence and the setting they meant is
/// buried, or an unrelated search lists settings.** The fusion is the Phase 0 winner's, ported
/// from the bench; the parity suite runs the bench's own practice searches through both.
@Suite("Settings search meaning fusion (#3482)", .tags(.productOutcome))
struct SettingsSearchMeaningFusionTests {

  // MARK: - Parity with the bench on the practice set

  /// `Tests/Fixtures/settings-search/meaning-fusion-parity-practice.json`: for each of the 699
  /// practice searches, the bench matcher's word results and the similarity of every place, plus
  /// the ranking the bench's own `rank` produced from them. Similarities are whole millionths.
  struct Fixture: Decodable {
    struct Source: Decodable {
      struct Knobs: Decodable {
        let fusion: String
        let threshold: Double
        let zMin: Double
        let meaningWeight: Double
      }
      let knobs: Knobs
      let cap: Int
      let simsScale: Double
      let practiceSHA256: String
    }
    struct Case: Decodable {
      let q: String
      let lang: String
      let style: String
      let expected: [String]
      /// [place index, coverage, score]
      let lex: [[Double]]
      let sims: [Int]
      let ranked: [Int]
    }
    let source: Source
    let entryIDs: [String]
    let cases: [Case]
  }

  static func loadFixture() throws -> Fixture {
    let url = RepoRoot.sourceURL(
      "Tests/Fixtures/settings-search/meaning-fusion-parity-practice.json")
    return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
  }

  static func wordHits(_ lex: [[Double]], ids: [String]) -> [SettingsSearchWordHit] {
    lex.map {
      SettingsSearchWordHit(entryID: ids[Int($0[0])], coverage: $0[1], score: $0[2])
    }
  }

  @Test("every practice search ranks as the bench ranked it, and the knobs are the frozen ones")
  func practiceSetParity() throws {
    let fixture = try Self.loadFixture()
    #expect(fixture.cases.count == 699)
    // The knobs the sealed finalists ran with, written here from runs/final-*.json.
    #expect(fixture.source.knobs.fusion == "rerank")
    #expect(fixture.source.knobs.threshold == 0.7)
    #expect(fixture.source.knobs.zMin == 3.5)
    #expect(fixture.source.knobs.meaningWeight == 200)
    #expect(SettingsSearchMeaningKnobs.frozen.threshold == 0.7)
    #expect(SettingsSearchMeaningKnobs.frozen.zMin == 3.5)
    #expect(SettingsSearchMeaningKnobs.frozen.meaningWeight == 200)
    #expect(SettingsSearchMeaningKnobs.frozen.cap == fixture.source.cap)

    var mismatches: [String] = []
    var reordered = 0
    var meaningOnly = 0
    for fixtureCase in fixture.cases {
      let sims = try #require(
        SettingsSearchMeaningSimilarities(
          entryIDs: fixture.entryIDs,
          values: fixtureCase.sims.map { Double($0) / fixture.source.simsScale }))
      let hits = Self.wordHits(fixtureCase.lex, ids: fixture.entryIDs)
      let fused = try #require(
        SettingsSearchMeaningFusion.rank(wordHits: hits, similarities: sims),
        "\(fixtureCase.q): the word hits named a place with no similarity")
      let expected = fixtureCase.ranked.map { fixture.entryIDs[$0] }
      if fused.map(\.entryID) != expected {
        mismatches.append("\(fixtureCase.lang) \(fixtureCase.q)")
      }
      // Word results first, in their own flagged group; meaning-only results after them.
      let wordCount = hits.count
      #expect(fused.prefix(wordCount).allSatisfy { $0.isMeaningOnly == false })
      #expect(fused.dropFirst(wordCount).allSatisfy { $0.isMeaningOnly })
      if fused.prefix(wordCount).map(\.entryID) != hits.prefix(fused.count).map(\.entryID) {
        reordered += 1
      }
      if fused.count > wordCount { meaningOnly += 1 }
    }
    #expect(
      mismatches.isEmpty, "\(mismatches.count) searches differ, first: \(mismatches.prefix(5))")
    // The set must actually reach each branch, or parity proves little: 181 reordered, 225 with
    // meaning-only additions when the fixture was made.
    #expect(reordered > 100, "only \(reordered) searches were re-ordered")
    #expect(meaningOnly > 100, "only \(meaningOnly) searches gained meaning-only results")
  }

  @Test("the fixture covers the searches that stand out and those that do not")
  func fixtureReachesTheStandOutTest() throws {
    let fixture = try Self.loadFixture()
    var standing = 0
    var rejected = 0
    for fixtureCase in fixture.cases {
      let sims = fixtureCase.sims.map { Double($0) / fixture.source.simsScale }
      let mean = sims.reduce(0, +) / Double(sims.count)
      let sd = (sims.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(sims.count))
        .squareRoot()
      if sd > 0, ((sims.max() ?? 0) - mean) / sd >= 3.5 { standing += 1 } else { rejected += 1 }
    }
    #expect(standing > 100 && rejected > 100, "stand out \(standing), rejected \(rejected)")
  }

  // MARK: - Hand-computed cases

  private func similarities(_ values: [Double]) throws -> SettingsSearchMeaningSimilarities {
    try #require(
      SettingsSearchMeaningSimilarities(
        entryIDs: (0..<values.count).map { "p\($0)" }, values: values))
  }

  private func ids(_ results: [SettingsSearchFusedResult]?) -> [String] {
    (results ?? []).map(\.entryID)
  }

  /// `count` places, all at 0.1 except `top`. Each case adds a few more high values, so `count`
  /// is chosen (by hand, in the comment of each case) to keep the best one's z above 3.5.
  private func standingOut(top: Int, count: Int, topValue: Double = 0.9) -> [Double] {
    (0..<count).map { $0 == top ? topValue : 0.1 }
  }

  @Test("meaning breaks ties between equal coverage, and coverage still decides first")
  func rerankOrder() throws {
    // p1 has the better word score; p2 has a much better meaning score.
    let sims = try similarities([0, 0.2, 0.9, 0.5])
    let hits = [
      SettingsSearchWordHit(entryID: "p1", coverage: 1, score: 100),
      SettingsSearchWordHit(entryID: "p2", coverage: 1, score: 60),
      SettingsSearchWordHit(entryID: "p3", coverage: 0.5, score: 100),
    ]
    // key = score/maxScore*100 + 200*similarity: p1 = 100 + 40, p2 = 60 + 180, p3 = 100 + 100,
    // but p3's lower coverage puts it last whatever its key.
    let fused = SettingsSearchMeaningFusion.rank(
      wordHits: hits, similarities: sims,
      knobs: SettingsSearchMeaningKnobs(threshold: 2, zMin: 3.5, meaningWeight: 200, cap: 30))
    #expect(ids(fused) == ["p2", "p1", "p3"])
  }

  @Test("equal keys keep the word matcher's order")
  func stableOrder() throws {
    let sims = try similarities([0.3, 0.3, 0.3])
    let hits = ["p2", "p0", "p1"].map { SettingsSearchWordHit(entryID: $0, coverage: 1, score: 50) }
    let fused = SettingsSearchMeaningFusion.rank(
      wordHits: hits, similarities: sims,
      knobs: SettingsSearchMeaningKnobs(threshold: 2, zMin: 3.5, meaningWeight: 200, cap: 30))
    #expect(ids(fused) == ["p2", "p0", "p1"])
  }

  // MARK: - A best word score of zero or below (#3545 T10)

  /// Knobs that add no meaning-only places, so only the word results' order is judged.
  private let rerankOnly = SettingsSearchMeaningKnobs(
    threshold: 2, zMin: 3.5, meaningWeight: 200, cap: 30)

  private func fuse(_ hits: [(String, Double, Double)], _ values: [Double]) throws -> [String] {
    let fused = SettingsSearchMeaningFusion.rank(
      wordHits: hits.map { SettingsSearchWordHit(entryID: $0.0, coverage: $0.1, score: $0.2) },
      similarities: try similarities(values), knobs: rerankOnly)
    let results = try #require(fused, "the fusion refused its inputs")
    #expect(results.allSatisfy { !$0.isMeaningOnly })
    return results.map(\.entryID)
  }

  @Test("a best word score of zero keeps the word order when meaning is equal")
  func zeroBestKeepsOrder() throws {
    // Word order p2, p0, p1 with scores 0, -10, -80; every similarity 0.5.
    let order = try fuse([("p2", 1, 0), ("p0", 1, -10), ("p1", 1, -80)], [0.5, 0.5, 0.5])
    #expect(order == ["p2", "p0", "p1"])
  }

  @Test("a negative best word score keeps the word order when meaning is equal, never reverses it")
  func negativeBestKeepsOrder() throws {
    // Scores -5, -20, -80: dividing by -5 would make them 100, 400, 1600 and reverse the list.
    let order = try fuse([("p2", 1, -5), ("p0", 1, -20), ("p1", 1, -80)], [0.5, 0.5, 0.5])
    #expect(order == ["p2", "p0", "p1"])
  }

  @Test(
    "with a best word score of zero or below, a clearly better meaning still moves a place up",
    arguments: [[0.0, -10, -80], [-5.0, -20, -80]])
  func nonPositiveBestStillReranks(scores: [Double]) throws {
    // Position scale 100, 66.7, 33.3 for p2, p0, p1. Similarities p0 0.1, p1 0.6, p2 0.1:
    // p2 = 100 + 20 = 120, p0 = 66.7 + 20 = 86.7, p1 = 33.3 + 120 = 153.3.
    let order = try fuse(
      [("p2", 1, scores[0]), ("p0", 1, scores[1]), ("p1", 1, scores[2])], [0.1, 0.6, 0.1])
    #expect(order == ["p1", "p2", "p0"])
  }

  @Test("with a best word score of zero or below, lower coverage stays behind whatever its meaning")
  func nonPositiveBestKeepsCoverageFirst() throws {
    let order = try fuse([("p0", 1, -10), ("p1", 0.5, -5)], [0.0, 1.0])
    #expect(order == ["p0", "p1"])
  }

  @Test("a positive best word score keeps the bench's score scaling, negative siblings included")
  func positiveBestUnchanged() throws {
    // Score scale 100, 90, -40 for p0, p1, p2; similarities 0.1, 0.2, 0.45:
    // p0 = 100 + 20 = 120, p1 = 90 + 40 = 130, p2 = -40 + 90 = 50.
    // (Position scaling would give p0 = 120, p1 = 106.7, p2 = 123.3 and put p2 first.)
    let order = try fuse([("p0", 1, 100), ("p1", 1, 90), ("p2", 1, -40)], [0.1, 0.2, 0.45])
    #expect(order == ["p1", "p0", "p2"])
  }

  @Test("a standing-out search adds meaning-only places at or above the threshold, best first")
  func meaningOnlyResults() throws {
    // 60 places: 56 at 0.1, then 0.9, 0.75, 0.70 and 0.6999. mean 0.1442, sd 0.1666, z = 4.5.
    var values = standingOut(top: 5, count: 60)
    values[7] = 0.75
    values[3] = 0.70  // exactly the threshold: included
    values[9] = 0.6999  // just below: not
    let fused = SettingsSearchMeaningFusion.rank(
      wordHits: [SettingsSearchWordHit(entryID: "p5", coverage: 1, score: 10)],
      similarities: try similarities(values))
    // p5 is a word result and also the best meaning; it appears once, as a word result.
    #expect(ids(fused) == ["p5", "p7", "p3"])
    #expect(fused?.map(\.isMeaningOnly) == [false, true, true])
  }

  @Test("equal similarities list meaning-only places in catalog order")
  func meaningTiesByCatalogOrder() throws {
    // 60 places: 57 at 0.1, one at 0.9 and two at 0.8. mean 0.1367, sd 0.1602, z = 4.8.
    var values = standingOut(top: 15, count: 60)
    values[4] = 0.8
    values[2] = 0.8
    let fused = SettingsSearchMeaningFusion.rank(
      wordHits: [], similarities: try similarities(values))
    #expect(ids(fused) == ["p15", "p2", "p4"])
  }

  @Test("a search that does not stand out from every place adds nothing")
  func unrelatedSearchesAddNothing() throws {
    // Ten places: one at 0.9 among nine at 0.1 has z = 3.0, below 3.5, so no meaning-only result
    // even though p3 is above the threshold.
    var values = [Double](repeating: 0.1, count: 10)
    values[3] = 0.9
    #expect(
      ids(SettingsSearchMeaningFusion.rank(wordHits: [], similarities: try similarities(values)))
        == [])
    // The word results are still re-ordered by meaning.
    let hits = [
      SettingsSearchWordHit(entryID: "p1", coverage: 1, score: 100),
      SettingsSearchWordHit(entryID: "p3", coverage: 1, score: 99),
    ]
    let fused = SettingsSearchMeaningFusion.rank(
      wordHits: hits, similarities: try similarities(values))
    // p1 = 100 + 200*0.1 = 120, p3 = 99/100*100 + 200*0.9 = 279
    #expect(ids(fused) == ["p3", "p1"])
    // All places equal: no spread, so nothing stands out.
    let flat = [Double](repeating: 0.8, count: 20)
    #expect(
      ids(SettingsSearchMeaningFusion.rank(wordHits: [], similarities: try similarities(flat)))
        == [])
  }

  @Test("results are cut at the cap")
  func capApplies() throws {
    // 100 places: 92 at 0.1, one at 0.9 and seven at 0.8. mean 0.157, sd 0.1935, z = 3.84.
    var values = standingOut(top: 0, count: 100)
    for index in 1..<8 { values[index] = 0.8 }
    let fused = SettingsSearchMeaningFusion.rank(
      wordHits: [], similarities: try similarities(values),
      knobs: SettingsSearchMeaningKnobs(threshold: 0.7, zMin: 3.5, meaningWeight: 200, cap: 3))
    #expect(ids(fused) == ["p0", "p1", "p2"])
  }

  @Test("a word result with no similarity is refused, never scored with a made-up value")
  func mismatchedInputsAreRefused() throws {
    let sims = try similarities([0.2, 0.3])
    let hits = [SettingsSearchWordHit(entryID: "elsewhere", coverage: 1, score: 1)]
    #expect(SettingsSearchMeaningFusion.rank(wordHits: hits, similarities: sims) == nil)
    #expect(SettingsSearchMeaningSimilarities(entryIDs: ["a"], values: []) == nil)
    #expect(SettingsSearchMeaningSimilarities(entryIDs: [], values: []) == nil)
  }
}
