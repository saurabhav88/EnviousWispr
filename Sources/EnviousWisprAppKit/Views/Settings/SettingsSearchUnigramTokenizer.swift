import Foundation

// periphery:ignore - meaning pass core for the Settings search UI chunk (#3482); tests drive it until then
/// The tokenizer of the Settings search meaning model: multilingual-e5's SentencePiece Unigram
/// (XLM-R vocabulary of 250,002 pieces), in Swift, with no dependency (#3482 plan §3.7a).
///
/// Why not a library: the tokenizer the app already links (ArgmaxOSS) segments this vocabulary
/// differently from the Hugging Face tokenizer the model and the Phase 0 bench used ("query:"
/// becomes ids 944, 1294 instead of 41, 1294), which moved every search vector (cosine 0.84 to
/// 0.95 against the reference). The Hugging Face Swift package would pull a network-capable Hub
/// client into the app. `SettingsSearchUnigramTokenizerTests` proves this one produces the Hugging
/// Face ids for every place text in 32 languages, the practice searches and fuzz.
///
/// Pipeline (all of it fixed by `scripts/settings-map/meaning-assets.py`, which refuses any other
/// tokenizer.json): literal special tokens are split off; the rest is normalized with the model's
/// precompiled SentencePiece table (per grapheme cluster, as the Hugging Face tokenizer does);
/// split on Unicode white space; every word gets a leading "▁"; each word is segmented by the
/// best-scoring Unigram path (ties go to the earlier-found path; characters no piece covers become
/// one unknown token, and consecutive unknown tokens are fused); `<s>` and `</s>` surround the ids.
///
/// The file is `tokenizer.unigram` (layout in `build_unigram`), about 6.8 MB against 17 MB for the
/// original tokenizer.json. Pieces are sorted by their UTF-8 bytes and found by binary search, so
/// loading is a copy of five arrays and nothing is built.
struct SettingsSearchUnigramTokenizer: Sendable {
  enum LoadError: Error, Equatable, CustomStringConvertible {
    case malformed(String)
    var description: String {
      switch self {
      case .malformed(let reason): "tokenizer.unigram is malformed: \(reason)"
      }
    }
  }

  private struct AddedToken: Sendable {
    let id: Int
    let bytes: [UInt8]
  }

  static let magic = Array("EWUNIG01".utf8)
  /// Unigram's penalty below the lowest piece score for a character no piece covers.
  private static let unknownPenalty = 10.0

  private let trie: [UInt32]
  private let pool: [UInt8]
  private let starts: [UInt32]
  private let pieceIDs: [UInt32]
  private let scores: [Double]
  private let blob: [UInt8]
  private let maxScalars: Int
  private let unknownID: Int
  private let beginID: Int
  private let endID: Int
  private let unknownScore: Double
  private let added: [AddedToken]

  init(data: Data) throws {
    var reader = Reader(data: data)
    guard reader.bytes(8) == Self.magic else {
      throw LoadError.malformed("not a tokenizer.unigram")
    }
    guard let count = reader.u32(), let unknown = reader.u32(), let longest = reader.u32(),
      let begin = reader.u32(), let end = reader.u32(), let flags = reader.u32(),
      let addedCount = reader.u32(), let trieBytes = reader.u32(), let poolBytes = reader.u32(),
      let blobBytes = reader.u32()
    else { throw LoadError.malformed("header is cut short") }
    guard count > 1, unknown < count, begin < count, end < count, longest >= 1,
      trieBytes % 4 == 0, trieBytes >= 8
    else { throw LoadError.malformed("header values are not plausible") }
    var added: [AddedToken] = []
    for _ in 0..<addedCount {
      guard let id = reader.u32(), let length = reader.u32(), let bytes = reader.bytes(Int(length))
      else { throw LoadError.malformed("added tokens are cut short") }
      added.append(AddedToken(id: Int(id), bytes: bytes))
    }
    guard let trieData = reader.bytes(Int(trieBytes)), let pool = reader.bytes(Int(poolBytes))
    else { throw LoadError.malformed("normalizer table is cut short") }
    var trie = [UInt32](repeating: 0, count: Int(trieBytes) / 4)
    for index in trie.indices {
      let base = index * 4
      trie[index] =
        UInt32(trieData[base]) | UInt32(trieData[base + 1]) << 8 | UInt32(trieData[base + 2]) << 16
        | UInt32(trieData[base + 3]) << 24
    }
    guard let starts = reader.u32s(Int(count) + 1), let pieceIDs = reader.u32s(Int(count)) else {
      throw LoadError.malformed("piece index is cut short")
    }
    let scoreValues: [Double]?
    if flags & 1 == 1 {
      scoreValues = reader.f32s(Int(count))
    } else {
      scoreValues = reader.f64s(Int(count))
    }
    guard let scores = scoreValues, let blob = reader.bytes(Int(blobBytes)), reader.isAtEnd else {
      throw LoadError.malformed("sizes do not add up to the file")
    }
    guard starts.first == 0, starts.last == blobBytes,
      zip(starts, starts.dropFirst()).allSatisfy({ $0 < $1 }),
      pieceIDs.allSatisfy({ $0 < count })
    else { throw LoadError.malformed("piece index is inconsistent") }
    self.trie = trie
    self.pool = pool
    self.starts = starts
    self.pieceIDs = pieceIDs
    self.scores = scores
    self.blob = blob
    self.maxScalars = Int(longest)
    self.unknownID = Int(unknown)
    self.beginID = Int(begin)
    self.endID = Int(end)
    self.unknownScore = (scores.min() ?? 0) - Self.unknownPenalty
    self.added = added
  }

  // MARK: - Encoding

  /// The ids for `text`, with `<s>` first and `</s>` last, as the Hugging Face tokenizer returns
  /// them for `encode(text)` with special tokens on.
  func encode(_ text: String) -> [Int] {
    var ids = [beginID]
    let bytes = Array(text.utf8)
    var segmentStart = 0
    var index = 0
    while index < bytes.count {
      if bytes[index] == UInt8(ascii: "<"), let token = literal(at: index, in: bytes) {
        appendSegment(bytes[segmentStart..<index], to: &ids)
        ids.append(token.id)
        index += token.bytes.count
        segmentStart = index
      } else {
        index += 1
      }
    }
    appendSegment(bytes[segmentStart...], to: &ids)
    ids.append(endID)
    return ids
  }

  private func literal(at index: Int, in bytes: [UInt8]) -> AddedToken? {
    added.first { token in
      index + token.bytes.count <= bytes.count
        && bytes[index..<index + token.bytes.count].elementsEqual(token.bytes)
    }
  }

  private func appendSegment(_ bytes: ArraySlice<UInt8>, to ids: inout [Int]) {
    guard bytes.isEmpty == false else { return }
    let text = String(decoding: bytes, as: UTF8.self)
    let normalized = normalize(text)
    var word = String.UnicodeScalarView()
    for scalar in normalized.unicodeScalars {
      if scalar.properties.isWhitespace {
        flush(&word, into: &ids)
      } else {
        word.append(scalar)
      }
    }
    flush(&word, into: &ids)
  }

  private func flush(_ word: inout String.UnicodeScalarView, into ids: inout [Int]) {
    guard word.isEmpty == false else { return }
    ids += segment("\u{2581}" + String(word))
    word = String.UnicodeScalarView()
  }

  // MARK: - Normalizer (precompiled SentencePiece table)

  /// Each grapheme cluster shorter than six bytes is looked up whole; otherwise each scalar is. A
  /// lookup replaces the chunk with the table's string for the SHORTEST matching prefix, dropping
  /// any bytes after that prefix, exactly as the Hugging Face normalizer does.
  func normalize(_ text: String) -> String {
    var out: [UInt8] = []
    out.reserveCapacity(text.utf8.count)
    for character in text {
      let bytes = Array(character.utf8)
      if bytes.count < 6, let mapped = transform(bytes) {
        out += mapped
        continue
      }
      for scalar in character.unicodeScalars {
        let scalarBytes = Array(String(scalar).utf8)
        out += transform(scalarBytes) ?? scalarBytes[...]
      }
    }
    return String(decoding: out, as: UTF8.self)
  }

  private func transform(_ key: [UInt8]) -> ArraySlice<UInt8>? {
    guard let value = firstPrefixValue(key), value < pool.count else { return nil }
    guard let end = pool[value...].firstIndex(of: 0) else { return nil }
    return pool[value..<end]
  }

  /// The value of the shortest key in the double-array trie that is a prefix of `key`.
  private func firstPrefixValue(_ key: [UInt8]) -> Int? {
    func offset(_ unit: UInt32) -> Int { Int((unit >> 10) << ((unit & 0x200) >> 6)) }
    var node = 0
    var unit = trie[node]
    node ^= offset(unit)
    for byte in key {
      if byte == 0 { break }
      node ^= Int(byte)
      guard node >= 0, node < trie.count else { return nil }
      unit = trie[node]
      if unit & 0x8000_00FF != UInt32(byte) { return nil }
      node ^= offset(unit)
      if (unit >> 8) & 1 == 1 {
        guard node >= 0, node < trie.count else { return nil }
        return Int(trie[node] & 0x7FFF_FFFF)
      }
    }
    return nil
  }

  // MARK: - Unigram segmentation

  private func segment(_ word: String) -> [Int] {
    let scalars = Array(word.unicodeScalars)
    var bytes: [UInt8] = []
    var offsets = [0]
    for scalar in scalars {
      bytes += Array(String(scalar).utf8)
      offsets.append(bytes.count)
    }
    let count = scalars.count
    var bestScore = [Double](repeating: -Double.greatestFiniteMagnitude, count: count + 1)
    var bestID = [Int](repeating: -1, count: count + 1)
    var bestStart = [Int](repeating: -1, count: count + 1)
    bestScore[0] = 0
    for start in 0..<count {
      let here = bestScore[start]
      var hasSingle = false
      for length in 1...min(maxScalars, count - start) {
        guard let id = pieceID(bytes, offsets[start], offsets[start + length]) else { continue }
        let score = here + scores[id]
        if score > bestScore[start + length] {
          bestScore[start + length] = score
          bestID[start + length] = id
          bestStart[start + length] = start
        }
        if length == 1 { hasSingle = true }
      }
      if hasSingle == false {
        let score = here + unknownScore
        if score > bestScore[start + 1] {
          bestScore[start + 1] = score
          bestID[start + 1] = unknownID
          bestStart[start + 1] = start
        }
      }
    }
    var ids: [Int] = []
    var end = count
    while end > 0 {
      ids.append(bestID[end])
      end = bestStart[end]
    }
    ids.reverse()
    var fused: [Int] = []
    for id in ids {
      if id == unknownID, fused.last == unknownID { continue }
      fused.append(id)
    }
    return fused
  }

  /// The vocabulary id of the piece spelled by `bytes[from..<to]`, by binary search over the
  /// pieces sorted by UTF-8 bytes.
  private func pieceID(_ bytes: [UInt8], _ from: Int, _ to: Int) -> Int? {
    var low = 0
    var high = starts.count - 1
    while low < high {
      let mid = (low + high) / 2
      let start = Int(starts[mid])
      let end = Int(starts[mid + 1])
      switch compare(start, end, bytes, from, to) {
      case 0: return Int(pieceIDs[mid])
      case ..<0: low = mid + 1
      default: high = mid
      }
    }
    return nil
  }

  /// Orders blob[start..<end] against key[from..<to] byte by byte, the shorter first on a tie.
  private func compare(_ start: Int, _ end: Int, _ key: [UInt8], _ from: Int, _ to: Int) -> Int {
    let shared = min(end - start, to - from)
    var position = 0
    while position < shared {
      let a = blob[start + position]
      let b = key[from + position]
      if a != b { return a < b ? -1 : 1 }
      position += 1
    }
    return (end - start) - (to - from)
  }

  // MARK: - File reading

  private struct Reader {
    let data: Data
    var offset = 0

    init(data: Data) { self.data = data }

    var isAtEnd: Bool { offset == data.count }

    mutating func bytes(_ count: Int) -> [UInt8]? {
      guard count >= 0, offset + count <= data.count else { return nil }
      let start = data.startIndex + offset
      defer { offset += count }
      return Array(data[start..<start + count])
    }

    mutating func u32() -> UInt32? {
      guard let b = bytes(4) else { return nil }
      return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
    }

    mutating func u32s(_ count: Int) -> [UInt32]? {
      guard let raw = bytes(count * 4) else { return nil }
      var out = [UInt32](repeating: 0, count: count)
      for index in 0..<count {
        let base = index * 4
        out[index] =
          UInt32(raw[base]) | UInt32(raw[base + 1]) << 8 | UInt32(raw[base + 2]) << 16
          | UInt32(raw[base + 3]) << 24
      }
      return out
    }

    mutating func f32s(_ count: Int) -> [Double]? {
      u32s(count)?.map { Double(Float(bitPattern: $0)) }
    }

    mutating func f64s(_ count: Int) -> [Double]? {
      guard let raw = bytes(count * 8) else { return nil }
      return (0..<count).map { index in
        var bits: UInt64 = 0
        for byte in 0..<8 { bits |= UInt64(raw[index * 8 + byte]) << UInt64(8 * byte) }
        return Double(bitPattern: bits)
      }
    }
  }
}
