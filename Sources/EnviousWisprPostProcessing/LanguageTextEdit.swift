import Foundation

// MARK: - Original text, UTF-16 coordinates and validated edits (#1677, PR 2 chunk 3)
//
// The language passes read and edit ONE immutable original text. Every coordinate is a UTF-16
// offset into that text, the same unit `NSString`/`NSRange` use, and every lookup form (case
// folding, NFC) is derived from a token while its range stays tied to the original bytes. Nothing
// here ever normalizes the whole text, so an untouched span comes back byte-identical.
//
// A pass proposes the smallest ACTUAL replacement range as a `LanguageTextEdit`. The editor
// applies a set of edits against the same snapshot or refuses the whole set: it never returns a
// partly edited text. Protection against already-written spans is checked here, so a pass cannot
// forget it.

/// One refusal reason per way an edit set can be wrong. Callers keep the original text.
enum LanguageEditRefusal: Error, Sendable, Equatable {
  /// A replacement must cover at least one UTF-16 unit: insertions are not part of this slice.
  case emptyRange
  /// The range is not inside the snapshot.
  case outOfBounds
  /// An endpoint falls inside an extended grapheme cluster (a combining sequence, a surrogate
  /// pair or CR LF), so the edit would split an original character.
  case splitsCharacter
  /// The edit was proposed against a different text than the one it is applied to.
  case staleSnapshot
  /// Two edits cover the same unit.
  case overlappingEdits
  /// The edit crosses a span that is already written.
  case intersectsProtectedSpan(LanguageProtectedSpan)
  /// A digit-regrouping edit whose replacement does not carry exactly the original ASCII digits in
  /// order, or whose range holds a non-ASCII decimal digit.
  case changesDigits
  /// A clock edit whose named chunks are not whole number chunks of one or two ASCII digits (an
  /// optional `h`), lie outside the edit or overlap, carry punctuation without ending the edit, or
  /// whose replacement drops that punctuation.
  case notAClockChunk
}

/// An immutable original text with UTF-16 coordinates.
struct LanguageTextSnapshot: Sendable, Equatable {
  let text: String
  /// The text as UTF-16 code units: the coordinate system of every range in this layer.
  let units: [UInt16]
  /// Content identity (FNV-1a over the UTF-8 bytes): an edit minted against another text is stale.
  let identity: UInt64
  /// UTF-16 offsets where an extended grapheme cluster starts, plus the end offset, ascending.
  private let characterBoundaries: [Int]

  init(_ text: String) {
    self.text = text
    self.units = Array(text.utf16)
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in text.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 0x0000_0100_0000_01b3
    }
    self.identity = hash
    var boundaries: [Int] = []
    var offset = 0
    for character in text {
      boundaries.append(offset)
      for scalar in character.unicodeScalars {
        offset += scalar.value > 0xFFFF ? 2 : 1
      }
    }
    boundaries.append(offset)
    self.characterBoundaries = boundaries
  }

  var utf16Count: Int { units.count }

  /// True when `offset` lies on a Unicode scalar boundary (not between the two halves of a
  /// surrogate pair) inside `0...utf16Count`.
  func isScalarBoundary(_ offset: Int) -> Bool {
    guard offset >= 0, offset <= units.count else { return false }
    if offset == 0 || offset == units.count { return true }
    let unit = units[offset]
    let previous = units[offset - 1]
    return !(UTF16.isTrailSurrogate(unit) && UTF16.isLeadSurrogate(previous))
  }

  /// True when `offset` starts (or ends) an extended grapheme cluster of the original text.
  func isCharacterBoundary(_ offset: Int) -> Bool {
    var low = 0
    var high = characterBoundaries.count - 1
    while low <= high {
      let mid = (low + high) / 2
      let value = characterBoundaries[mid]
      if value == offset { return true }
      if value < offset { low = mid + 1 } else { high = mid - 1 }
    }
    return false
  }

  func contains(_ range: Range<Int>) -> Bool {
    range.lowerBound >= 0 && range.upperBound <= units.count
  }

  /// The original text of a range, or nil when the range is outside the text or splits a
  /// Unicode scalar. Read-only: inspecting a protected span never edits it.
  func substring(_ range: Range<Int>) -> String? {
    guard contains(range), isScalarBoundary(range.lowerBound), isScalarBoundary(range.upperBound)
    else { return nil }
    return String(decoding: units[range], as: UTF16.self)
  }

  /// Mints an edit against this snapshot, or says why the proposal is invalid.
  func edit(replacing range: Range<Int>, with replacement: String)
    -> Result<LanguageTextEdit, LanguageEditRefusal>
  {
    if let refusal = validate(range) { return .failure(refusal) }
    return .success(
      LanguageTextEdit(range: range, replacement: replacement, snapshotIdentity: identity))
  }

  /// Mints an edit that may rewrite already-written NUMBER chunks it fully covers, because it
  /// keeps their digits: the replacement must carry exactly the ASCII digits of the original range,
  /// in order, and the range must hold no other decimal digit. The editor checks both again when
  /// it applies the edit, and still refuses any address, money or measurement span and any number
  /// chunk the edit covers only in part. For a pass that has validated a complete number and only
  /// regroups it (the phone pass); every other edit uses `edit(replacing:with:)`.
  func edit(regroupingDigitsIn range: Range<Int>, with replacement: String)
    -> Result<LanguageTextEdit, LanguageEditRefusal>
  {
    if let refusal = validate(range) { return .failure(refusal) }
    guard keepsDigits(range, replacement) else { return .failure(.changesDigits) }
    return .success(
      LanguageTextEdit(
        range: range, replacement: replacement, snapshotIdentity: identity,
        permission: .regroupsDigits))
  }

  /// Mints an edit that replaces a spoken clock idiom whose hour or minutes the engine already
  /// wrote as digits (`halb 8` to `7:30`, `9 menos cuarto` to `8:45`). It names EVERY number chunk
  /// it consumes: each must be a whole number chunk of one or two ASCII digits, optionally followed
  /// by `h` (`8h`), inside the edit; closing punctuation is allowed only on a chunk that ends the
  /// edit, and the replacement must end with that same punctuation, so a sentence mark or a bracket
  /// is carried, never dropped. The digits may change (a "to" idiom moves the hour back): the
  /// clock meaning is the pass's decision, the editor checks the shape. The editor checks all of it
  /// again on apply and refuses any other protected span the edit touches. For the clock passes;
  /// every other edit uses `edit(replacing:with:)` or `edit(regroupingDigitsIn:with:)`.
  func edit(
    replacing range: Range<Int>, consumingClockChunks chunks: [Range<Int>],
    with replacement: String
  ) -> Result<LanguageTextEdit, LanguageEditRefusal> {
    if let refusal = validate(range) { return .failure(refusal) }
    guard isClockEdit(range, chunks: chunks, replacement: replacement) else {
      return .failure(.notAClockChunk)
    }
    return .success(
      LanguageTextEdit(
        range: range, replacement: replacement, snapshotIdentity: identity,
        permission: .replacesClockChunks(chunks)))
  }

  /// Mints an edit that rewrites a written number together with the unit word after it ("48
  /// Prozent" to "48%"): like `edit(regroupingDigitsIn:with:)` it must keep exactly the original
  /// ASCII digits, and it may also cover WHOLE measurement chunks; the editor checks both again and
  /// still refuses any address or money span and any chunk covered in part.
  func edit(rewritingNumberAndUnitIn range: Range<Int>, with replacement: String)
    -> Result<LanguageTextEdit, LanguageEditRefusal>
  {
    if let refusal = validate(range) { return .failure(refusal) }
    guard keepsDigits(range, replacement) else { return .failure(.changesDigits) }
    return .success(
      LanguageTextEdit(
        range: range, replacement: replacement, snapshotIdentity: identity,
        permission: .rewritesNumberAndUnit))
  }

  /// Closing punctuation a clock chunk may carry after its digits.
  private static let clockChunkClosing = Set(".,;:!?)]}\"'»”’“‘".unicodeScalars.map(\.value))

  /// True when `chunks` is a nonempty ascending list of disjoint ranges inside `range`, each one or
  /// two ASCII digits, an optional `h`, then closing punctuation only when the chunk ends `range`
  /// (and `replacement` ends with that punctuation).
  fileprivate func isClockEdit(_ range: Range<Int>, chunks: [Range<Int>], replacement: String)
    -> Bool
  {
    guard !chunks.isEmpty else { return false }
    var previousEnd = range.lowerBound
    for chunk in chunks {
      guard !chunk.isEmpty, chunk.lowerBound >= previousEnd, chunk.upperBound <= range.upperBound,
        let text = substring(chunk)
      else { return false }
      previousEnd = chunk.upperBound
      let scalars = Array(text.unicodeScalars)
      var index = 0
      while index < scalars.count, (0x30...0x39).contains(scalars[index].value) { index += 1 }
      guard (1...2).contains(index) else { return false }
      if index < scalars.count, scalars[index] == "h" { index += 1 }
      guard scalars[index...].allSatisfy({ Self.clockChunkClosing.contains($0.value) }) else {
        return false
      }
      if index < scalars.count {
        guard chunk.upperBound == range.upperBound else { return false }
        var closing = String.UnicodeScalarView()
        closing.append(contentsOf: scalars[index...])
        guard replacement.hasSuffix(String(closing)) else { return false }
      }
    }
    return true
  }

  /// True when `replacement` holds exactly the ASCII digits of `range`, in order, and neither
  /// side holds a non-ASCII decimal digit.
  fileprivate func keepsDigits(_ range: Range<Int>, _ replacement: String) -> Bool {
    guard let original = substring(range) else { return false }
    func asciiDigits(_ text: String) -> [UInt8]? {
      var digits: [UInt8] = []
      for scalar in text.unicodeScalars {
        if scalar.value >= 0x30 && scalar.value <= 0x39 {
          digits.append(UInt8(scalar.value))
        } else if scalar.properties.numericType == .decimal {
          return nil
        }
      }
      return digits
    }
    guard let before = asciiDigits(original), let after = asciiDigits(replacement) else {
      return false
    }
    return before == after
  }

  fileprivate func validate(_ range: Range<Int>) -> LanguageEditRefusal? {
    guard contains(range) else { return .outOfBounds }
    guard !range.isEmpty else { return .emptyRange }
    guard isCharacterBoundary(range.lowerBound), isCharacterBoundary(range.upperBound) else {
      return .splitsCharacter
    }
    return nil
  }
}

/// One proposed replacement: a nonempty UTF-16 range of the original text and its new text.
struct LanguageTextEdit: Sendable, Equatable {
  let range: Range<Int>
  let replacement: String
  /// The identity of the snapshot this edit was proposed against.
  let snapshotIdentity: UInt64
  /// Which already-written number chunks the edit may cover. The editor rechecks every permission
  /// against the snapshot, so a forged value is refused.
  let permission: Permission

  enum Permission: Sendable, Equatable {
    /// No protected span may be touched.
    case plain
    /// Minted by `edit(regroupingDigitsIn:with:)`: may cover whole number chunks, digits kept.
    case regroupsDigits
    /// Minted by `edit(replacing:consumingClockChunks:with:)`: may replace exactly these whole
    /// number chunks of a clock idiom.
    case replacesClockChunks([Range<Int>])
    /// Minted by `edit(rewritingNumberAndUnitIn:with:)`: may cover whole number and measurement
    /// chunks, digits kept ("48 Prozent" to "48%").
    case rewritesNumberAndUnit
  }

  var regroupsDigits: Bool { permission == .regroupsDigits }

  init(
    range: Range<Int>, replacement: String, snapshotIdentity: UInt64,
    permission: Permission = .plain
  ) {
    self.range = range
    self.replacement = replacement
    self.snapshotIdentity = snapshotIdentity
    self.permission = permission
  }
}

enum LanguageEditOutcome: Sendable, Equatable {
  case applied(String)
  case refused(LanguageEditRefusal)
}

enum LanguageTextEditor {

  /// Applies every edit against the SAME snapshot, or none of them.
  ///
  /// Refuses a stale edit, an invalid range, two edits that overlap, and any edit that crosses a
  /// protected span. The editor collects the protected spans of THIS snapshot itself, so a caller
  /// can neither omit protection nor supply spans that belong to another text. Two edits that
  /// merely touch (one ends where the next starts) are allowed.
  /// The result is composed forward from the original code units, so no edit can invalidate the
  /// coordinates of another. An empty edit list returns the original text unchanged.
  static func apply(
    _ edits: [LanguageTextEdit], to snapshot: LanguageTextSnapshot
  ) -> LanguageEditOutcome {
    let spans = LanguageProtectedSpans.collect(in: snapshot)
    for edit in edits {
      guard edit.snapshotIdentity == snapshot.identity else { return .refused(.staleSnapshot) }
      if let refusal = snapshot.validate(edit.range) { return .refused(refusal) }
    }
    let ordered = edits.sorted { $0.range.lowerBound < $1.range.lowerBound }
    for (earlier, later) in zip(ordered, ordered.dropFirst())
    where earlier.range.upperBound > later.range.lowerBound {
      return .refused(.overlappingEdits)
    }
    for edit in ordered {
      // Each permission is checked again here: it is a property of a value, so the editor cannot
      // trust that the snapshot minted it.
      let intersecting = spans.filter {
        $0.range.lowerBound < edit.range.upperBound && edit.range.lowerBound < $0.range.upperBound
      }
      switch edit.permission {
      case .plain:
        if let span = intersecting.first { return .refused(.intersectsProtectedSpan(span)) }
      case .regroupsDigits:
        guard snapshot.keepsDigits(edit.range, edit.replacement) else {
          return .refused(.changesDigits)
        }
        for span in intersecting {
          let covered =
            edit.range.lowerBound <= span.range.lowerBound
            && span.range.upperBound <= edit.range.upperBound
          guard span.kind == .number, covered else {
            return .refused(.intersectsProtectedSpan(span))
          }
        }
      case .rewritesNumberAndUnit:
        guard snapshot.keepsDigits(edit.range, edit.replacement) else {
          return .refused(.changesDigits)
        }
        for span in intersecting {
          let covered =
            edit.range.lowerBound <= span.range.lowerBound
            && span.range.upperBound <= edit.range.upperBound
          guard span.kind == .number || span.kind == .measurement, covered else {
            return .refused(.intersectsProtectedSpan(span))
          }
        }
      case .replacesClockChunks(let chunks):
        guard snapshot.isClockEdit(edit.range, chunks: chunks, replacement: edit.replacement)
        else { return .refused(.notAClockChunk) }
        for span in intersecting where span.kind != .number || !chunks.contains(span.range) {
          return .refused(.intersectsProtectedSpan(span))
        }
        // Every named chunk must BE a number span of this snapshot, not a stretch of words.
        let numberRanges = Set(intersecting.filter { $0.kind == .number }.map(\.range))
        guard chunks.allSatisfy({ numberRanges.contains($0) }) else {
          return .refused(.notAClockChunk)
        }
      }
    }
    var output: [UInt16] = []
    output.reserveCapacity(snapshot.units.count)
    var cursor = 0
    for edit in ordered {
      output.append(contentsOf: snapshot.units[cursor..<edit.range.lowerBound])
      output.append(contentsOf: edit.replacement.utf16)
      cursor = edit.range.upperBound
    }
    output.append(contentsOf: snapshot.units[cursor...])
    return .applied(String(decoding: output, as: UTF16.self))
  }
}
