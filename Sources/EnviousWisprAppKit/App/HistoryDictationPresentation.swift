import CryptoKit
import EnviousWisprCore
import EnviousWisprStorage
import Foundation

/// The pure decisions behind one dictation's History card (#3147 §3.4): which words each view
/// shows, how the Marked up view reads, where paragraphs break, which change a click opened and
/// when each passage is heard in the recording. Nothing here touches a view, a store or the
/// main actor, so the card can run `prepare` off the main actor and tests can pin every rule.
///
/// **Two texts, named for what they are.** `original` is the row's stored pre-AI text
/// (`Transcript.text`): "your words before AI polish", which can include the speech engine's own
/// mistakes, never untouched speech-engine output. `polished` is what History calls the polished
/// version (`displayText`: polished, else processed, else the original).
enum HistoryDictationPresentation {

  /// The card's temporary comparison views. Choosing one never changes the row's saved
  /// preference (§3.4); it only changes what this card shows until it closes.
  enum TextView: Equatable, Sendable {
    case polished
    case markedUp
    case original
  }

  // MARK: - Texts

  /// The two stored texts one card compares, plus the engine's language for the case fold.
  /// Its value is the content identity of a prepared comparison: a result is only ever shown
  /// for the exact texts it was computed from.
  struct Texts: Hashable, Sendable {
    let original: String
    let polished: String
    let language: String?

    init(original: String, polished: String, language: String?) {
      self.original = original
      self.polished = polished
      self.language = language
    }

    init(_ row: Transcript) {
      self.init(original: row.text, polished: row.displayText, language: row.language)
    }

    /// Whether AI polish (or processing) produced different text. Compared by UTF-16 units,
    /// so two Unicode spellings of the same word still count as a difference to show.
    var differ: Bool { !original.utf16.elementsEqual(polished.utf16) }

    static func == (lhs: Texts, rhs: Texts) -> Bool {
      lhs.original.utf16.elementsEqual(rhs.original.utf16)
        && lhs.polished.utf16.elementsEqual(rhs.polished.utf16) && lhs.language == rhs.language
    }

    func hash(into hasher: inout Hasher) {
      hasher.combine(Array(original.utf16))
      hasher.combine(Array(polished.utf16))
      hasher.combine(language)
    }
  }

  /// The words a view shows when edits are off or on its plain views. Marked up has no plain
  /// form; it reads `Prepared.markedUp`.
  static func plainText(_ texts: Texts, view: TextView) -> String {
    view == .original ? texts.original : texts.polished
  }

  /// The view the card opens in: the row's saved preference (§3.4: "Opening the card honors the
  /// saved preference").
  static func defaultView(for preference: Transcript.PreferredVersion) -> TextView {
    preference == .original ? .original : .polished
  }

  /// The view Show edits switches to: Marked up, as the approved mock does.
  static let editsView: TextView = .markedUp

  // MARK: - Prepared comparison

  /// One run of the Marked up view, in reading order.
  struct MarkRun: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
      /// Words the cleanup kept, or the whitespace between runs.
      case same
      /// Original words the cleanup removed or replaced: struck through.
      case removed
      /// Polished words the cleanup put in: highlighted.
      case added
    }
    let kind: Kind
    let text: String
    /// The change this run belongs to (an index into `Prepared.alignment.changes`); nil for
    /// `.same`.
    let change: Int?
    /// Where the run starts in the original text (UTF-16), for `.same` and `.removed`.
    let originalOffset: Int?
  }

  /// A comparison ready to draw. Built off the main actor by `prepare`.
  struct Prepared: Equatable, Sendable {
    let texts: Texts
    let alignment: WordDiff.Alignment
    let markedUp: [MarkRun]

    /// Show edits is offered only when there is something to show.
    var hasChanges: Bool { !alignment.changes.isEmpty }
  }

  /// Aligns the two texts and builds the Marked up runs. Cost is `WordDiff`'s (linear in length
  /// and edit distance), so the card calls it off the main actor.
  static func prepare(_ texts: Texts) -> Prepared {
    let alignment = WordDiff.alignment(
      original: texts.original, cleaned: texts.polished, language: texts.language)
    return Prepared(
      texts: texts, alignment: alignment,
      markedUp: markedUpRuns(texts: texts, alignment: alignment))
  }

  /// `prepare` on a background executor, so a long dictation never stalls the History list.
  @concurrent static func prepareInBackground(_ texts: Texts) async -> Prepared {
    prepare(texts)
  }

  /// A prepared result is shown only while it still answers the card's current texts; a slower
  /// result for texts the row no longer has (a restore, an edit) is dropped.
  static func accepts(_ result: Prepared, current: Texts?) -> Bool {
    result.texts == current
  }

  /// The Marked up document: kept words and the whitespace between them as the polished text
  /// has them, each change as its removed original words then its added polished words. A
  /// removed run never touches a neighbour without a space, so "um" never reads as "umso".
  static func markedUpRuns(texts: Texts, alignment: WordDiff.Alignment) -> [MarkRun] {
    let original = texts.original
    let polished = texts.polished
    enum Item {
      case span(WordDiff.EqualSpan)
      case change(Int, WordDiff.Change)
      var cleaned: Range<Int> {
        switch self {
        case .span(let s): s.cleanedRange
        case .change(_, let c): c.cleanedRange
        }
      }
      var originalLower: Int {
        switch self {
        case .span(let s): s.originalRange.lowerBound
        case .change(_, let c): c.originalRange.lowerBound
        }
      }
      var insertsOnly: Bool {
        if case .change(_, let c) = self { return c.originalRange.isEmpty }
        return false
      }
    }
    // Both lists are in reading order on both sides; merge by original position, an insertion
    // at a point going before a span that starts there.
    var items: [Item] = []
    var si = 0
    var ci = 0
    let spans = alignment.equalSpans
    let changes = alignment.changes
    while si < spans.count || ci < changes.count {
      let takeSpan: Bool
      if si == spans.count {
        takeSpan = false
      } else if ci == changes.count {
        takeSpan = true
      } else {
        let s = spans[si].originalRange.lowerBound
        let c = changes[ci].originalRange
        takeSpan = s < c.lowerBound || (s == c.lowerBound && !c.isEmpty)
      }
      if takeSpan {
        items.append(.span(spans[si]))
        si += 1
      } else {
        items.append(.change(ci, changes[ci]))
        ci += 1
      }
    }

    var runs: [MarkRun] = []
    func append(_ run: MarkRun) {
      guard !run.text.isEmpty else { return }
      if let last = runs.last, last.kind == .removed || run.kind == .removed,
        last.text.last?.isWhitespace == false, run.text.first?.isWhitespace == false
      {
        runs.append(MarkRun(kind: .same, text: " ", change: nil, originalOffset: nil))
      }
      runs.append(run)
    }
    var cursor = 0  // polished UTF-16 position already emitted
    for item in items {
      let cleaned = item.cleaned
      if cleaned.lowerBound > cursor {
        append(
          MarkRun(
            kind: .same, text: slice(polished, cursor..<cleaned.lowerBound), change: nil,
            originalOffset: nil))
      }
      switch item {
      case .span(let span):
        append(
          MarkRun(
            kind: .same, text: slice(polished, span.cleanedRange), change: nil,
            originalOffset: span.originalRange.lowerBound))
      case .change(let index, let change):
        append(
          MarkRun(
            kind: .removed, text: slice(original, change.originalRange), change: index,
            originalOffset: change.originalRange.lowerBound))
        append(
          MarkRun(
            kind: .added, text: slice(polished, change.cleanedRange), change: index,
            originalOffset: nil))
      }
      cursor = max(cursor, cleaned.upperBound)
    }
    let total = polished.utf16.count
    if cursor < total {
      append(
        MarkRun(
          kind: .same, text: slice(polished, cursor..<total), change: nil, originalOffset: nil))
    }
    return runs
  }

  // MARK: - Paragraphs

  /// One block of the card's text: a line of the shown text with its UTF-16 range in that
  /// text. Blank lines separate blocks and are not blocks themselves.
  struct Paragraph: Equatable, Sendable {
    let range: Range<Int>
    let text: String
  }

  /// The shown text's non-empty lines, in order.
  static func paragraphs(of text: String) -> [Paragraph] {
    var out: [Paragraph] = []
    var start = 0
    var offset = 0
    var line = ""
    func flush() {
      if !line.trimmingCharacters(in: .whitespaces).isEmpty {
        out.append(Paragraph(range: start..<offset, text: line))
      }
      line = ""
    }
    for c in text {
      if c.isNewline {
        flush()
        offset += c.utf16.count
        start = offset
      } else {
        line.append(c)
        offset += c.utf16.count
      }
    }
    flush()
    return out
  }

  /// The Marked up runs split into blocks at line breaks, keeping each run's kind and change.
  static func markedUpParagraphs(_ runs: [MarkRun]) -> [[MarkRun]] {
    var out: [[MarkRun]] = []
    var current: [MarkRun] = []
    func flush() {
      if current.contains(where: { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }) {
        out.append(current)
      }
      current = []
    }
    for run in runs {
      // Split at line breaks by Character, counting UTF-16 units, so "\r\n" (one Character,
      // two units) keeps the original offsets of the pieces after it right.
      var piece = ""
      var pieceStart = run.originalOffset
      var offset = run.originalOffset
      func emit() {
        if !piece.isEmpty {
          current.append(
            MarkRun(kind: run.kind, text: piece, change: run.change, originalOffset: pieceStart))
        }
        piece = ""
      }
      for c in run.text {
        offset = offset.map { $0 + c.utf16.count }
        if c.isNewline {
          emit()
          flush()
          pieceStart = offset
        } else {
          piece.append(c)
        }
      }
      emit()
    }
    flush()
    return out
  }

  // MARK: - Recording times

  /// A passage heard at `seconds`, as a UTF-16 range of the ORIGINAL text.
  struct TimedSpan: Equatable, Sendable {
    let range: Range<Int>
    let seconds: Double
  }

  /// The prefix PR1 and lane C write into `RecordingTiming.textVersion` for anchors that index
  /// the exact speech-engine text (`DictationRecordings.timing(for:)`).
  static let exactASRVersionPrefix = "asr-sha256:"

  /// The recording's passage times carried onto the original text. Anchors index the exact
  /// speech-engine text; they are trusted only when the sidecar's version identity matches
  /// that text, and each anchor is kept only when both its first and last character fall in
  /// text the processing left literally unchanged. Everything else stays untimed: a time
  /// button is never guessed from a neighbour.
  static func timeline(_ timing: RecordingTiming?, original: String) -> [TimedSpan] {
    guard let timing, let exact = timing.exactASRText, !timing.anchors.isEmpty,
      timing.textVersion == exactASRVersionPrefix + sha256Hex(exact)
    else { return [] }
    let count = exact.utf16.count
    let alignment = WordDiff.alignment(original: exact, cleaned: original)
    return timing.anchors.compactMap { anchor -> TimedSpan? in
      guard anchor.utf16Start >= 0, anchor.utf16Start < anchor.utf16End,
        anchor.utf16End <= count, anchor.startSeconds.isFinite, anchor.startSeconds >= 0
      else { return nil }
      guard let range = project(anchor.utf16Start..<anchor.utf16End, through: alignment.equalSpans)
      else { return nil }
      return TimedSpan(range: range, seconds: anchor.startSeconds)
    }
    .sorted { $0.range.lowerBound < $1.range.lowerBound }
  }

  /// Carries original-text passage times onto the polished text through the same rule.
  static func polishedTimeline(_ spans: [TimedSpan], alignment: WordDiff.Alignment)
    -> [TimedSpan]
  {
    spans.compactMap { span in
      project(span.range, through: alignment.equalSpans).map {
        TimedSpan(range: $0, seconds: span.seconds)
      }
    }
  }

  /// `range` in the target text, when its first and last characters both sit in literally
  /// unchanged stretches; nil otherwise.
  static func project(_ range: Range<Int>, through spans: [WordDiff.EqualSpan]) -> Range<Int>? {
    guard !range.isEmpty, let start = project(range.lowerBound, through: spans),
      let last = project(range.upperBound - 1, through: spans), last >= start
    else { return nil }
    return start..<(last + 1)
  }

  static func project(_ offset: Int, through spans: [WordDiff.EqualSpan]) -> Int? {
    // Binary search: spans are sorted and disjoint on the source side.
    var lo = 0
    var hi = spans.count
    while lo < hi {
      let mid = (lo + hi) / 2
      let r = spans[mid].originalRange
      if offset < r.lowerBound {
        hi = mid
      } else if offset >= r.upperBound {
        lo = mid + 1
      } else {
        return spans[mid].cleanedRange.lowerBound + (offset - r.lowerBound)
      }
    }
    return nil
  }

  /// A block's time: the first passage that starts inside it. Nil leaves the gutter empty.
  static func time(of block: Range<Int>, in spans: [TimedSpan]) -> Double? {
    spans.first { block.contains($0.range.lowerBound) }?.seconds
  }

  /// A Marked up block's time, read from the original positions of its kept and removed runs.
  static func time(ofMarkedUp block: [MarkRun], in spans: [TimedSpan]) -> Double? {
    let offsets = block.compactMap { run in
      run.originalOffset.map { $0..<($0 + run.text.utf16.count) }
    }
    guard let lower = offsets.map(\.lowerBound).min(),
      let upper = offsets.map(\.upperBound).max()
    else { return nil }
    return time(of: lower..<upper, in: spans)
  }

  // MARK: - Change inspector

  /// What the change inspector shows for one change: both sides' words and, when the change's
  /// original words were heard in a timed passage, where. An insertion has no original words and
  /// stays untimed.
  struct ChangeDetail: Equatable, Sendable {
    let original: String
    let polished: String
    let seconds: Double?
  }

  static func detail(of index: Int, in prepared: Prepared, timeline: [TimedSpan])
    -> ChangeDetail?
  {
    guard prepared.alignment.changes.indices.contains(index) else { return nil }
    let change = prepared.alignment.changes[index]
    let seconds: Double? =
      change.originalRange.isEmpty
      ? nil
      : timeline.first { $0.range.contains(change.originalRange.lowerBound) }?.seconds
    return ChangeDetail(
      original: slice(prepared.texts.original, change.originalRange),
      polished: slice(prepared.texts.polished, change.cleanedRange), seconds: seconds)
  }

  // MARK: - Preference and deletion

  /// The More menu's text choice for a row: Restore original text while History uses the
  /// polished words and they differ from the original, Use polished text while it uses the
  /// original. Nil for rows History keeps no preference on (imports, meetings, held rows).
  enum PreferenceAction: Equatable, Sendable {
    case restoreOriginal
    case usePolished
  }

  static func preferenceAction(for row: Transcript) -> PreferenceAction? {
    guard !row.isImported, !row.isMeeting, row.escapeRecoveredAt == nil else { return nil }
    switch row.effectivePreferredVersion {
    case .original: return .usePolished
    case .polished: return Texts(row).differ ? .restoreOriginal : nil
    }
  }

  /// Whether a deletion outcome means the card must say it did not work. Already gone is not a
  /// failure; a deliberate skip is not either.
  static func deletionFailed(_ outcome: HistoryDeleteOutcome) -> Bool {
    outcome == .failed
  }

  // MARK: - Footer

  /// "Recording until Nov 18" needs the date the keep period ends; nil when recordings are kept
  /// until the user deletes them, or this one is kept.
  static func recordingExpiry(savedAt: Date, keepDays: Int?, pinned: Bool) -> Date? {
    guard !pinned, let keepDays else { return nil }
    return savedAt.addingTimeInterval(Double(keepDays) * 86_400)
  }

  /// "0:07" for a seek position.
  static func clock(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded(.down)))
    return String(format: "%d:%02d", total / 60, total % 60)
  }

  // MARK: - Helpers

  static func slice(_ text: String, _ range: Range<Int>) -> String {
    TranscriptDocumentPresenter.slice(text, range)
  }

  static func sha256Hex(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}

/// Prepared comparisons by content (#3147 §3.4), so a card scrolled out of the diary and back
/// does not align its texts again. Keyed by the exact texts, so a restored or re-polished row
/// can never pick up another version's result. Bounded: the oldest entry goes first.
@MainActor
final class HistoryDiffCache {
  static let shared = HistoryDiffCache(limit: 64)

  private let limit: Int
  private var entries: [HistoryDictationPresentation.Texts: HistoryDictationPresentation.Prepared] = [:]
  private var order: [HistoryDictationPresentation.Texts] = []

  init(limit: Int) {
    self.limit = max(1, limit)
  }

  func result(for texts: HistoryDictationPresentation.Texts) -> HistoryDictationPresentation.Prepared? {
    guard let hit = entries[texts] else { return nil }
    touch(texts)
    return hit
  }

  func store(_ prepared: HistoryDictationPresentation.Prepared) {
    entries[prepared.texts] = prepared
    touch(prepared.texts)
    while order.count > limit {
      entries[order.removeFirst()] = nil
    }
  }

  var count: Int { entries.count }

  private func touch(_ texts: HistoryDictationPresentation.Texts) {
    order.removeAll { $0 == texts }
    order.append(texts)
  }
}
