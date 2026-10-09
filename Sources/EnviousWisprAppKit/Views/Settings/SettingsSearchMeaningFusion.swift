import Foundation

// periphery:ignore - meaning pass core for the Settings search UI chunk (#3482); tests drive it until then
/// One word-search result, as the meaning pass takes it (#3482 plan §3.7 item 8). The word
/// matcher produces these in its own order; this file defines only the shape it hands over.
struct SettingsSearchWordHit: Equatable, Sendable {
  /// The Settings Map id of the matched entry.
  let entryID: String
  /// The share of the query's meaningful tokens the entry matched (plan §3.2). Ranked first.
  let coverage: Double
  /// The word matcher's score for the entry (plan §3.2).
  let score: Double
}

// periphery:ignore - meaning pass core for the Settings search UI chunk (#3482); tests drive it until then
/// How similar each searchable entry is to the typed search, from the meaning model. One value per
/// entry in `entryIDs` order; the order is the catalog's and decides ties.
struct SettingsSearchMeaningSimilarities: Equatable, Sendable {
  let entryIDs: [String]
  let values: [Double]

  init?(entryIDs: [String], values: [Double]) {
    guard entryIDs.count == values.count, entryIDs.isEmpty == false else { return nil }
    self.entryIDs = entryIDs
    self.values = values
  }
}

// periphery:ignore - meaning pass core for the Settings search UI chunk (#3482); tests drive it until then
/// The fusion knobs the Phase 0 bench froze into the sealed finalists (`runs/final-*.json`: rerank,
/// threshold 0.7, zMin 3.5, meaningWeight 200; the practice grid chose the same point), and the
/// result cap the matcher uses (plan §3.2).
struct SettingsSearchMeaningKnobs: Equatable, Sendable {
  /// A meaning-only result needs at least this similarity.
  var threshold: Double
  /// The best similarity must stand out from all entries by this many standard deviations, or the
  /// meaning pass adds no results (it rejects searches that are unrelated to every setting).
  var zMin: Double
  /// How much similarity adds to a word result's score (the score is scaled to 0 through 100).
  var meaningWeight: Double
  var cap: Int

  static let frozen = SettingsSearchMeaningKnobs(
    threshold: 0.7, zMin: 3.5, meaningWeight: 200, cap: 30)
}

// periphery:ignore - meaning pass core for the Settings search UI chunk (#3482); tests drive it until then
/// One result of the fused list. A meaning-only result matched no authored word, so the row shows
/// no "Matches" hint for it (plan §3.7 item 8).
struct SettingsSearchFusedResult: Equatable, Sendable {
  let entryID: String
  let isMeaningOnly: Bool
}

// periphery:ignore - meaning pass core for the Settings search UI chunk (#3482); tests drive it until then
/// The Phase 0 winner's "rerank" fusion as a pure function (#3482 plan §3.7a). Word results are
/// re-ordered by meaning, and entries only the meaning model found follow them. Ported from the
/// bench's `rank` (`settings_search_bench`, `Sources/SettingsSearchBench/main.swift`, commit
/// e818a753); `SettingsSearchMeaningFusionTests` runs the bench's practice set through both.
enum SettingsSearchMeaningFusion {
  /// The results, best first, at most `knobs.cap`.
  ///
  /// Returns nil when the inputs disagree (a word result with no similarity, which means the word
  /// index and the place vectors describe different entries). The caller keeps the word order then;
  /// a gap is never filled with a made-up similarity.
  static func rank(
    wordHits: [SettingsSearchWordHit], similarities: SettingsSearchMeaningSimilarities,
    knobs: SettingsSearchMeaningKnobs = .frozen
  ) -> [SettingsSearchFusedResult]? {
    var indexByID: [String: Int] = [:]
    indexByID.reserveCapacity(similarities.entryIDs.count)
    for (index, id) in similarities.entryIDs.enumerated() { indexByID[id] = index }
    let sims = similarities.values
    var hitIndexes: [Int] = []
    hitIndexes.reserveCapacity(wordHits.count)
    for hit in wordHits {
      guard let index = indexByID[hit.entryID] else { return nil }
      hitIndexes.append(index)
    }

    let mean = sims.reduce(0, +) / Double(sims.count)
    let sd = (sims.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(sims.count)).squareRoot()
    let top = sims.max() ?? 0
    let standsOut = sd > 0 && (top - mean) / sd >= knobs.zMin
    // Highest similarity first; the catalog order settles equal values.
    let meaningOrder =
      standsOut
      ? sims.indices.filter { sims[$0] >= knobs.threshold }.sorted {
        sims[$0] != sims[$1] ? sims[$0] > sims[$1] : $0 < $1
      } : []

    let maxScore = wordHits.map(\.score).max() ?? 1
    // The word score on a 0 to 100 scale. A best score of zero or below (a place bias such as
    // Transcribe a File's -80 can make every score negative) cannot be divided by: zero gives no
    // number and a negative divisor reverses the order. Then the word matcher's own order is the
    // scale instead, from 100 for its first result down to 100 / count for its last (#3545 plan
    // §3.5, T10). A positive best score keeps the bench's score scaling unchanged.
    func wordScale(_ position: Int) -> Double {
      guard maxScore > 0 else {
        return 100 * Double(wordHits.count - position) / Double(wordHits.count)
      }
      return wordHits[position].score / maxScore * 100
    }
    func key(_ position: Int) -> (Double, Double) {
      (
        wordHits[position].coverage,
        wordScale(position) + knobs.meaningWeight * sims[hitIndexes[position]]
      )
    }
    // Stable on purpose: equal keys keep the word matcher's order.
    let reranked = wordHits.indices.sorted { a, b in
      let (ka, kb) = (key(a), key(b))
      if ka != kb { return ka > kb }
      return a < b
    }

    var results = reranked.map {
      SettingsSearchFusedResult(entryID: wordHits[$0].entryID, isMeaningOnly: false)
    }
    let seen = Set(hitIndexes)
    for index in meaningOrder where seen.contains(index) == false {
      results.append(
        SettingsSearchFusedResult(entryID: similarities.entryIDs[index], isMeaningOnly: true))
    }
    return Array(results.prefix(knobs.cap))
  }
}
