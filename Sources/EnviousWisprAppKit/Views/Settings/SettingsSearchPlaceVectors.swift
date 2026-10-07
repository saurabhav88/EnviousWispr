import Accelerate
import Foundation

// periphery:ignore - meaning pass core for the Settings search UI chunk (#3482); tests drive it until then
/// The precomputed place vectors of the Settings search meaning pass (#3482 plan §3.7a): one
/// 384-number vector per distinct place text, embedded ahead of time with the full-quality
/// fine-tuned model and stored as float16 (the Phase 0 bench's practice set ranks identically with
/// float16 vectors; 8-bit storage changed 6 of 699). Only the typed search is encoded on the Mac.
///
/// A place's meaning score is its best-matching row among the rows of the ACTIVE languages
/// (plan §3.7a: lexical fields and scored place-vector views include only the active snapshot).
struct SettingsSearchPlaceVectors: Sendable {
  struct EntryRows: Decodable, Equatable, Sendable {
    /// Interface language code -> the row of "name. description".
    let main: [String: Int]
    /// Vocabulary language code -> rows of its title, phrases and joined words.
    let languages: [String: [Int]]
  }

  private struct Index: Decodable {
    let schema: String
    let version: Int
    let dimension: Int
    let dtype: String
    let rows: Int
    let textsSHA256: String
    let entries: [String: EntryRows]
  }

  enum LoadError: Error, Equatable, CustomStringConvertible {
    case inconsistent(String)
    var description: String {
      switch self {
      case .inconsistent(let reason): "place vectors inconsistent: \(reason)"
      }
    }
  }

  let dimension: Int
  let rowCount: Int
  let textsSHA256: String
  let entries: [String: EntryRows]
  private let rows: [Float16]

  /// Rows are `rowCount` vectors of `dimension` half-precision numbers, row-major.
  init(
    dimension: Int, rowCount: Int, textsSHA256: String, entries: [String: EntryRows],
    rows: [Float16]
  ) {
    precondition(rows.count == dimension * rowCount, "place vector rows do not match their shape")
    self.dimension = dimension
    self.rowCount = rowCount
    self.textsSHA256 = textsSHA256
    self.entries = entries
    self.rows = rows
  }

  /// Reads and checks the index and the vectors against the manifest, never partially.
  static func load(
    assets: SettingsSearchMeaningAssets, manifest: SettingsSearchMeaningAssets.Manifest
  )
    throws -> SettingsSearchPlaceVectors
  {
    let entry = manifest.placeVectors
    let indexData = try assets.verifiedData("place-vectors.json", against: entry.index)
    let binData = try assets.verifiedData("place-vectors.bin", against: entry.bin)
    let index: Index
    do {
      index = try JSONDecoder().decode(Index.self, from: indexData)
    } catch {
      throw LoadError.inconsistent("index is not readable: \(error.localizedDescription)")
    }
    guard index.schema == "settings-search-place-vectors", index.version == 1,
      index.dtype == "float16", index.dimension == entry.dimension,
      index.dimension == manifest.encoder.dimension, index.rows == entry.rows,
      index.textsSHA256 == entry.textsSHA256
    else { throw LoadError.inconsistent("index and manifest disagree") }
    guard binData.count == index.rows * index.dimension * MemoryLayout<Float16>.size else {
      throw LoadError.inconsistent("vector file size does not match rows x dimension")
    }
    for (id, rows) in index.entries {
      let all = Array(rows.main.values) + rows.languages.values.flatMap { $0 }
      guard all.allSatisfy({ (0..<index.rows).contains($0) }) else {
        throw LoadError.inconsistent("\(id) names a row outside the file")
      }
    }
    let values = binData.withUnsafeBytes { Array($0.bindMemory(to: Float16.self)) }
    guard values.count == index.rows * index.dimension, values.allSatisfy({ $0.isFinite }) else {
      throw LoadError.inconsistent("vectors are not finite")
    }
    return SettingsSearchPlaceVectors(
      dimension: index.dimension, rowCount: index.rows, textsSHA256: index.textsSHA256,
      entries: index.entries, rows: values)
  }

  /// The rows one window session scores: each place's name row in the app language and its rows in
  /// every active vocabulary language. The place order is the caller's (the catalog's); a place
  /// with no row in this view scores -1, as in the bench.
  ///
  /// Nil when a requested place has no entry at all, which means the assets were built from
  /// another map: the caller skips the meaning pass instead of scoring a partial index.
  func view(
    entryIDs: [String], appLanguage: String, vocabularyLanguages: [String]
  ) -> View? {
    var local: [Int: Int32] = [:]
    var chosen: [Int] = []
    var perEntry: [[Int32]] = []
    perEntry.reserveCapacity(entryIDs.count)
    for id in entryIDs {
      guard let entry = entries[id] else { return nil }
      var wanted: [Int] = []
      if let main = entry.main[appLanguage] { wanted.append(main) }
      for language in vocabularyLanguages { wanted += entry.languages[language] ?? [] }
      var mine: [Int32] = []
      for row in wanted {
        if let existing = local[row] {
          mine.append(existing)
        } else {
          let next = Int32(chosen.count)
          local[row] = next
          chosen.append(row)
          mine.append(next)
        }
      }
      perEntry.append(mine)
    }
    var matrix = [Float](repeating: 0, count: chosen.count * dimension)
    for (slot, row) in chosen.enumerated() {
      let source = row * dimension
      var norm: Float = 0
      for column in 0..<dimension {
        let value = Float(rows[source + column])
        matrix[slot * dimension + column] = value
        norm += value * value
      }
      // The bench scores unit vectors; float16 storage moves each norm by about 1e-3.
      norm = norm.squareRoot()
      if norm > 0 {
        for column in 0..<dimension { matrix[slot * dimension + column] /= norm }
      }
    }
    return View(entryIDs: entryIDs, dimension: dimension, matrix: matrix, rowsByEntry: perEntry)
  }

  struct View: Sendable {
    let entryIDs: [String]
    let dimension: Int
    let rowCount: Int
    private let matrix: [Float]
    private let rowsByEntry: [[Int32]]

    fileprivate init(
      entryIDs: [String], dimension: Int, matrix: [Float], rowsByEntry: [[Int32]]
    ) {
      self.entryIDs = entryIDs
      self.dimension = dimension
      self.rowCount = matrix.count / max(dimension, 1)
      self.matrix = matrix
      self.rowsByEntry = rowsByEntry
    }

    /// Each place's best cosine similarity to `query`, in `entryIDs` order. Nil when the vector has
    /// the wrong length or is not finite, or has no length to normalize.
    func similarities(query: [Float]) -> SettingsSearchMeaningSimilarities? {
      guard query.count == dimension, query.allSatisfy({ $0.isFinite }) else { return nil }
      let norm = query.reduce(0) { $0 + $1 * $1 }.squareRoot()
      guard norm > 0 else { return nil }
      let unit = query.map { $0 / norm }
      var scores = [Float](repeating: 0, count: rowCount)
      if rowCount > 0 {
        matrix.withUnsafeBufferPointer { a in
          unit.withUnsafeBufferPointer { x in
            scores.withUnsafeMutableBufferPointer { y in
              cblas_sgemv(
                CblasRowMajor, CblasNoTrans, Int32(rowCount), Int32(dimension), 1,
                a.baseAddress, Int32(dimension), x.baseAddress, 1, 0, y.baseAddress, 1)
            }
          }
        }
      }
      let values = rowsByEntry.map { rows in
        rows.map { Double(scores[Int($0)]) }.max() ?? -1
      }
      return SettingsSearchMeaningSimilarities(entryIDs: entryIDs, values: values)
    }
  }
}
