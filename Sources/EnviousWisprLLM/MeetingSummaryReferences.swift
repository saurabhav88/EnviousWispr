import EnviousWisprCore
import Foundation

/// One transcript turn a summary may point back to (#3147 PR4A, D5): the turn's stable id, the
/// speaker name History shows for it (nil when unnamed) and the words History shows for it.
public struct MeetingSummaryTurnSource: Sendable, Equatable {
  public let id: String
  public let speaker: String?
  public let text: String

  public init(id: String, speaker: String?, text: String) {
    self.id = id
    self.speaker = speaker
    self.text = text
  }
}

/// One note block a summary may point back to: the block's id and its text.
public struct MeetingSummaryNoteSource: Sendable, Equatable {
  public let blockID: UUID
  public let text: String

  public init(blockID: UUID, text: String) {
    self.blockID = blockID
    self.text = text
  }
}

/// The identity-bearing inputs of one summary: the visible turns and the note blocks, in order.
/// Tags (`[T1]`, `[N1]`) are their 1-based positions here, so a tag the model writes resolves
/// to exactly one source.
public struct MeetingSummaryReferenceSources: Sendable, Equatable {
  public let turns: [MeetingSummaryTurnSource]
  public let notes: [MeetingSummaryNoteSource]

  public init(turns: [MeetingSummaryTurnSource], notes: [MeetingSummaryNoteSource]) {
    self.turns = turns
    self.notes = notes
  }

  /// The transcript exactly as `MeetingTranscriptProjection.plainText` writes it from the same
  /// turns ("Name: words" paragraphs). The summary owner uses these sources only when this
  /// equals the transcript it hashes, so a tag never points into text the summary was not
  /// written from.
  public var plainTranscript: String {
    turns.map { turn in
      if let speaker = turn.speaker, !speaker.isEmpty { return "\(speaker): \(turn.text)" }
      return turn.text
    }.joined(separator: "\n\n")
  }

  /// The transcript the model reads: each paragraph led by its turn's tag.
  public var taggedTranscript: String {
    zip(turns.indices, turns).map { index, turn in
      let words =
        (turn.speaker.map { !$0.isEmpty } ?? false) ? "\(turn.speaker!): \(turn.text)" : turn.text
      return "[T\(index + 1)] \(words)"
    }.joined(separator: "\n\n")
  }

  /// The notes the model reads: one line per block, led by its tag.
  public var taggedNotes: String {
    zip(notes.indices, notes).map { index, note in
      "[N\(index + 1)] \(note.text)"
    }.joined(separator: "\n")
  }
}

/// Versioned summary references (#3147 PR4A, D5). A summary written on a qualified route sees
/// tagged turns and notes and ends each bullet with the tags of the lines it used; the tags are
/// removed from the Markdown the user reads and kept as candidate citations in a
/// `MeetingSummaryDocument` saved beside it. A citation is only a candidate: the app links an
/// item only when the validator (`MeetingSummaryReferenceValidator`) finds the whole item, with
/// whitespace normalized and nothing else changed, in a current source whose hash, range and
/// quote all agree. Paraphrase, partial support and stale or edited summaries get no link, and
/// no second model judges anything.
public enum MeetingSummaryReferences {
  /// The summary prompt version on a qualified route; the plain route keeps
  /// `MeetingSummary.promptVersion`.
  public static let promptVersion = 6

  /// The file beside `summary.md` that holds the reference document.
  public static let sidecarFileName = "summary-references.json"

  // MARK: - Qualification

  /// The routes whose reference output was qualified on real runs (receipt: the #3147 PR4A
  /// lane C provider qualification table). Every other route writes the plain summary exactly
  /// as before: readable, with no links, and never a changed provider or model.
  public static func isQualified(provider: LLMProvider, model: String) -> Bool {
    switch provider {
    case .appleIntelligence: return qualifiedAppleIntelligence
    case .ollama: return qualifiedOllamaModels.contains(model)
    // Not qualified: EG-1 (the 2026-11-13 run: the mini and micro sizes wrote no tags, and
    // every size failed the long meeting, as its plain prompt also does), hosted routes
    // (qualifying them is cloud spend that needs the founder's approval), and engines that
    // write no summary.
    case .egOne, .openAI, .gemini, .claude, .s1Mini, .none: return false
    }
  }

  /// Qualified 2026-11-13 on macOS 27.2 (three made-up meetings, one written in parts).
  static let qualifiedAppleIntelligence = true
  /// Exact Ollama model names qualified on this Mac (2026-11-13, the same three meetings).
  static let qualifiedOllamaModels: Set<String> = ["qwen3:8b"]

  // MARK: - Sources from a meeting row

  /// The visible turns of a meeting row with the words History shows for each, built exactly
  /// as `MeetingTranscriptProjection.plainText` builds its paragraphs (same visibility, slice,
  /// trim, empty-turn skip and `line` rewrite), so `plainTranscript` of the result equals that
  /// text for the same arguments.
  public static func turnSources(
    text: String, turns: [Turn], speakerNames: [String: String], echoTurnIDs: Set<String>,
    showEcho: Bool, line: (String) -> String = { $0 }
  ) -> [MeetingSummaryTurnSource] {
    let utf16 = Array(text.utf16)
    return MeetingTranscriptProjection.visible(
      turns: turns, echoTurnIDs: echoTurnIDs, showEcho: showEcho
    ).turns.compactMap { turn in
      let lower = max(0, min(turn.originalTextRange.lowerBound, utf16.count))
      let upper = max(lower, min(turn.originalTextRange.upperBound, utf16.count))
      let words = String(decoding: utf16[lower..<upper], as: UTF16.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !words.isEmpty else { return nil }
      let name = speakerNames[turn.speakerId].flatMap { $0.isEmpty ? nil : $0 }
      return MeetingSummaryTurnSource(id: turn.id, speaker: name, text: line(words))
    }
  }

  // MARK: - Prompt text

  /// Added to the summary's instructions on a qualified route.
  static let instructions = """
    Each transcript line starts with a tag such as [T12], and each of the user's notes with a \
    tag such as [N3]. End every bullet and every Overview sentence with the tags of the lines \
    it is based on, for example [T12] or [T4][N2]. Use only tags that appear in the input; \
    never invent one.
    """

  /// Added to a part request on a qualified route.
  static let partClause = " End each bullet with the tags of the lines it came from."
  /// Added to a combine or shortening request on a qualified route.
  static let keepClause = " Keep each bullet's tags."

  // MARK: - Tags

  /// One source a tag names, by its 1-based position.
  enum Tag: Equatable, Hashable {
    case turn(Int)
    case note(Int)
  }

  /// A tag group found in a line: its UTF-16 range (with the horizontal whitespace before it)
  /// and the tags it names, in order.
  struct TagGroup {
    let range: Range<Int>
    let tags: [Tag]
  }

  /// The tag groups of one line. A group is `[` + one or more `T<n>`/`N<n>` tokens separated by
  /// commas, semicolons, spaces or a dash (a range names its two ends) + `]`; anything else in
  /// brackets is ordinary text and stays.
  static func tagGroups(in line: String) -> [TagGroup] {
    let units = Array(line.utf16)
    var groups: [TagGroup] = []
    var index = 0
    while index < units.count {
      guard units[index] == 0x5B /* [ */,
        let close = units[(index + 1)...].firstIndex(of: 0x5D /* ] */)
      else {
        index += 1
        continue
      }
      let inner = String(decoding: units[(index + 1)..<close], as: UTF16.self)
      if let tags = parseTags(inner) {
        var start = index
        while start > 0, units[start - 1] == 0x20 || units[start - 1] == 0x09 { start -= 1 }
        groups.append(TagGroup(range: start..<(close + 1), tags: tags))
        index = close + 1
      } else {
        index += 1
      }
    }
    return groups
  }

  private static func parseTags(_ inner: String) -> [Tag]? {
    let separators = CharacterSet(charactersIn: ",;- \t")
    let tokens = inner.components(separatedBy: separators).filter { !$0.isEmpty }
    guard !tokens.isEmpty else { return nil }
    var tags: [Tag] = []
    for token in tokens {
      guard let kind = token.first, kind == "T" || kind == "N" else { return nil }
      let digits = token.dropFirst()
      guard (1...5).contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isNumber }),
        let number = Int(digits), number > 0
      else { return nil }
      tags.append(kind == "T" ? .turn(number) : .note(number))
    }
    return tags
  }

  /// The text with every tag group removed (and the spaces before it), line by line; a line
  /// that held only tags goes. Trailing whitespace is trimmed as the summary always was.
  public static func strippingTags(_ text: String) -> String {
    let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
    var kept: [String] = []
    for line in lines {
      let (stripped, tags) = strip(line)
      if !tags.isEmpty, stripped.trimmingCharacters(in: .whitespaces).isEmpty { continue }
      kept.append(stripped)
    }
    return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// One line without its tag groups, and the tags they named in order.
  static func strip(_ line: String) -> (text: String, tags: [Tag]) {
    let groups = tagGroups(in: line)
    guard !groups.isEmpty else { return (line, []) }
    var units = Array(line.utf16)
    for group in groups.reversed() { units.removeSubrange(group.range) }
    let text = String(decoding: units, as: UTF16.self)
    // Only trailing whitespace: a bullet's indentation is part of its Markdown.
    var end = text.endIndex
    while end > text.startIndex, text[text.index(before: end)].isWhitespace {
      end = text.index(before: end)
    }
    // Removing a group can complete another ("[T1 [N1]]" leaves "[T1]"): strip again until
    // none is left. Each pass removes characters, so this ends.
    let rest = strip(String(text[..<end]))
    return (rest.text, groups.flatMap(\.tags) + rest.tags)
  }

  // MARK: - Building the document

  /// The structured document for a summary's Markdown (`summary`, after the title line is
  /// split off and tags removed: the exact text the store saves) and the tags found in the
  /// tagged answer it came from (`taggedSummary`, the same lines before removal). Headings
  /// open sections; every other non-empty line is one item: a bullet's text after its marker,
  /// or a paragraph line. Each tag that names a real source becomes a candidate citation; its
  /// quote and range are the passage holding the whole item, or empty when no such passage
  /// exists in that source (the validator then refuses it). Nil when the two texts do not
  /// line up.
  public static func document(
    taggedSummary: String, summary: String, sources: MeetingSummaryReferenceSources,
    inputs: SummaryInputs, newID: () -> UUID = UUID.init
  ) -> MeetingSummaryDocument? {
    guard MeetingDocumentHash.sameBytes(strippingTags(taggedSummary), summary) else { return nil }
    var sections: [MeetingSummarySection] = []
    var title = ""
    var items: [MeetingSummaryItem] = []
    var sectionID = newID()
    func closeSection() {
      if !items.isEmpty || !title.isEmpty {
        sections.append(MeetingSummarySection(id: sectionID, title: title, items: items))
      }
      items = []
    }
    let lines = taggedSummary.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
    for line in lines {
      let (stripped, tags) = strip(line)
      let content = stripped.trimmingCharacters(in: .whitespaces)
      if content.isEmpty {
        // A line that held only tags belongs to the item before it.
        if !tags.isEmpty, let last = items.popLast() {
          items.append(
            MeetingSummaryItem(
              id: last.id, text: last.text,
              citations: last.citations
                + citations(for: tags, text: last.text, sources: sources, skipping: last)))
        }
        continue
      }
      if let heading = headingTitle(content) {
        closeSection()
        title = heading
        sectionID = newID()
        continue
      }
      let text = itemText(content)
      guard !text.isEmpty else { continue }
      items.append(
        MeetingSummaryItem(
          id: newID(), text: text,
          citations: citations(for: tags, text: text, sources: sources, skipping: nil)))
    }
    closeSection()
    return MeetingSummaryDocument(
      inputs: inputs, renderedMarkdownSHA256: MeetingDocumentHash.sha256(summary),
      sections: sections)
  }

  private static func headingTitle(_ line: String) -> String? {
    guard line.hasPrefix("#") else { return nil }
    let title = line.drop(while: { $0 == "#" })
    guard title.first == " " || title.isEmpty else { return nil }
    return title.trimmingCharacters(in: .whitespaces)
  }

  /// A bullet's text after its marker (`- `, `* `, `+ `, `1. `, `1) `); a paragraph unchanged.
  private static func itemText(_ line: String) -> String {
    for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
      return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
    }
    let digits = line.prefix(while: { $0.isASCII && $0.isNumber })
    if !digits.isEmpty, digits.count <= 3 {
      let rest = line.dropFirst(digits.count)
      if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
        return String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces)
      }
    }
    return line
  }

  private static func citations(
    for tags: [Tag], text: String, sources: MeetingSummaryReferenceSources,
    skipping existing: MeetingSummaryItem?
  ) -> [MeetingSummaryCitation] {
    var seen = (existing?.citations ?? []).map(\.source)
    var result: [MeetingSummaryCitation] = []
    for tag in tags {
      let source: MeetingSummarySource
      let sourceText: String
      switch tag {
      case .turn(let number):
        guard number <= sources.turns.count else { continue }
        let turn = sources.turns[number - 1]
        source = .turn(id: turn.id, textSHA256: MeetingDocumentHash.sha256(turn.text))
        sourceText = turn.text
      case .note(let number):
        guard number <= sources.notes.count else { continue }
        let note = sources.notes[number - 1]
        source = .note(blockID: note.blockID, textSHA256: MeetingDocumentHash.sha256(note.text))
        sourceText = note.text
      }
      guard !seen.contains(source) else { continue }
      seen.append(source)
      if let range = passage(holding: text, in: sourceText) {
        result.append(
          MeetingSummaryCitation(
            source: source, quote: slice(sourceText, range), rangeUTF16: range))
      } else {
        result.append(MeetingSummaryCitation(source: source, quote: "", rangeUTF16: 0..<0))
      }
    }
    return result
  }

  // MARK: - Extractive matching (shared by generation and the validator)

  /// The text with every run of Unicode whitespace made one space and the ends trimmed: the
  /// only difference between a claim and its passage the validator allows.
  public static func normalized(_ text: String) -> String {
    String(decoding: normalizedUnits(text).units, as: UTF16.self)
  }

  /// The UTF-16 slice `range` of `text`, or "" when the range lies outside it.
  /// A range that cuts a surrogate pair in half is outside the text too: decoding half a
  /// pair would make a replacement character the source never held.
  public static func slice(_ text: String, _ range: Range<Int>) -> String {
    let units = Array(text.utf16)
    guard range.lowerBound >= 0, range.upperBound <= units.count,
      range.lowerBound == units.count || !UTF16.isTrailSurrogate(units[range.lowerBound]),
      range.upperBound == units.count || !UTF16.isTrailSurrogate(units[range.upperBound])
    else { return "" }
    return String(decoding: units[range], as: UTF16.self)
  }

  /// Whether `document`'s sections and items are exactly the ones `markdown` reads as (titles
  /// and item texts, in order, by bytes), so a document can never link an item the summary
  /// does not show.
  /// Item ids must be unique too: a link is chosen by id.
  public static func describes(_ document: MeetingSummaryDocument, markdown: String) -> Bool {
    let itemIDs = document.sections.flatMap(\.items).map(\.id)
    guard Set(itemIDs).count == itemIDs.count else { return false }
    guard
      let parsed = self.document(
        taggedSummary: markdown, summary: markdown,
        sources: MeetingSummaryReferenceSources(turns: [], notes: []), inputs: document.inputs),
      parsed.sections.count == document.sections.count
    else { return false }
    return zip(parsed.sections, document.sections).allSatisfy { expected, actual in
      MeetingDocumentHash.sameBytes(expected.title, actual.title)
        && expected.items.count == actual.items.count
        && zip(expected.items, actual.items).allSatisfy {
          MeetingDocumentHash.sameBytes($0.0.text, $0.1.text)
        }
    }
  }

  /// Whether the passage `rangeUTF16` of `source` is the whole `claim` (whitespace normalized)
  /// and starts and ends at a word edge: every condition the builder puts on a citation's
  /// range, checked again on a saved candidate.
  public static func supportsWholeClaim(
    _ claim: String, in source: String, rangeUTF16: Range<Int>
  ) -> Bool {
    sameClaim(slice(source, rangeUTF16), claim)
      && atWordEdges(rangeUTF16, in: Array(source.utf16))
  }

  /// Whether `quote` and `claim` are the same words with whitespace normalized, compared by
  /// UTF-8 bytes (never Swift's canonical equivalence).
  public static func sameClaim(_ quote: String, _ claim: String) -> Bool {
    let a = normalized(quote)
    let b = normalized(claim)
    return !a.isEmpty && MeetingDocumentHash.sameBytes(a, b)
  }

  /// The UTF-16 range of `source` whose normalized text is the whole normalized `claim`,
  /// starting and ending at a word edge, or nil.
  static func passage(holding claim: String, in source: String) -> Range<Int>? {
    let needle = normalizedUnits(claim).units
    guard !needle.isEmpty else { return nil }
    let hay = normalizedUnits(source)
    guard needle.count <= hay.units.count else { return nil }
    let scalars = Array(source.utf16)
    var start = 0
    while start + needle.count <= hay.units.count {
      if hay.units[start] == needle[0],
        Array(hay.units[start..<(start + needle.count)]) == needle
      {
        let range = hay.starts[start]..<hay.ends[start + needle.count - 1]
        if atWordEdges(range, in: scalars) { return range }
      }
      start += 1
    }
    return nil
  }

  /// Normalized UTF-16 units, each with the source offsets it came from.
  private static func normalizedUnits(_ text: String)
    -> (units: [UInt16], starts: [Int], ends: [Int])
  {
    var units: [UInt16] = []
    var starts: [Int] = []
    var ends: [Int] = []
    var offset = 0
    var pendingSpace: Int?
    for scalar in text.unicodeScalars {
      let width = UTF16.width(scalar)
      defer { offset += width }
      if scalar.properties.isWhitespace {
        if !units.isEmpty, pendingSpace == nil { pendingSpace = offset }
        continue
      }
      if let space = pendingSpace {
        units.append(0x20)
        starts.append(space)
        ends.append(space + 1)
        pendingSpace = nil
      }
      for unit in String(scalar).utf16 {
        units.append(unit)
        starts.append(offset)
        ends.append(offset + width)
      }
    }
    return (units, starts, ends)
  }

  /// A passage may not begin or end inside a word of a spaced script ("ship" inside
  /// "shipping"); scripts written without spaces have no such edge to check.
  static func atWordEdges(_ range: Range<Int>, in units: [UInt16]) -> Bool {
    func scalar(at index: Int, backward: Bool) -> Unicode.Scalar? {
      guard index >= 0, index < units.count else { return nil }
      var i = index
      if backward, UTF16.isTrailSurrogate(units[i]), i > 0 { i -= 1 }
      let end = UTF16.isLeadSurrogate(units[i]) && i + 1 < units.count ? i + 2 : i + 1
      return String(decoding: units[i..<end], as: UTF16.self).unicodeScalars.first
    }
    func joins(_ a: Unicode.Scalar?, _ b: Unicode.Scalar?) -> Bool {
      guard let a, let b else { return false }
      return isWordScalar(a) && isWordScalar(b) && !isUnspacedScript(a) && !isUnspacedScript(b)
    }
    let before = scalar(at: range.lowerBound - 1, backward: true)
    let first = scalar(at: range.lowerBound, backward: false)
    let last = scalar(at: range.upperBound - 1, backward: true)
    let after = scalar(at: range.upperBound, backward: false)
    return !joins(before, first) && !joins(last, after)
  }

  private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
    scalar.properties.isAlphabetic || scalar.properties.numericType != nil
  }

  private static func isUnspacedScript(_ scalar: Unicode.Scalar) -> Bool {
    if scalar.properties.isIdeographic { return true }
    switch scalar.value {
    case 0x0E00...0x0E7F,  // Thai
      0x0E80...0x0EFF,  // Lao
      0x1000...0x109F,  // Myanmar
      0x1780...0x17FF,  // Khmer
      0x3040...0x30FF,  // Hiragana, Katakana
      0x31F0...0x31FF, 0xFF66...0xFF9D:  // Katakana extensions, half-width Katakana
      return true
    default: return false
    }
  }

  // MARK: - The saved file

  /// The bytes of `summary-references.json`.
  public static func encode(_ document: MeetingSummaryDocument) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(document)
  }

  /// The document in `data`, or nil when it cannot be read or has a version this build does
  /// not know. Nil never hides the summary: it only means no links.
  public static func decode(_ data: Data) -> MeetingSummaryDocument? {
    guard let document = try? JSONDecoder().decode(MeetingSummaryDocument.self, from: data),
      document.version == MeetingSummaryDocument.currentVersion
    else { return nil }
    return document
  }
}
