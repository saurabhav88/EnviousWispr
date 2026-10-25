import EnviousWisprCore
import Foundation

/// Builds a recording meeting's live words, per track, from transcript events (#3973).
///
/// A pure value: the meeting owner feeds it each track's `LiveWordsEvent`s with the meeting
/// clock and reads `lines`. Per track it keeps confirmed lines, one replaceable provisional
/// suffix and frozen uncertain spans.
///
/// - An update appends its finalized delta and replaces the provisional suffix. Finalized text
///   is never deduplicated by comparison: a repeated spoken word is a word.
/// - The provisional suffix belongs to one line. The finalized text that resolves it lands in
///   that line; the next suffix stays there only while the line is open, else it moves to a
///   new line that then owns it.
/// - A discontinuity, or the session's end, freezes the provisional suffix as uncertain text
///   (shown, never replaced) and clears it. Later recognition may overlap uncertain text; the
///   assembler never duplicates finalized text.
/// - A line closes when the other track produced words after it started, when its confirmed
///   text passed `maxLineCharacters`, or after `pauseMs` with no words on its track.
///
/// Times are the meeting clock in milliseconds, supplied by the caller: approximate display
/// times, not the final transcript's.
package struct LiveWordsAssembler: Sendable, Equatable {

  /// One displayed line of live words.
  package struct Line: Sendable, Equatable, Identifiable {
    package enum Kind: Sendable, Equatable {
      case confirmed
      /// Words that were in progress when the engine discarded them: a best guess.
      case uncertain
      /// Words still changing.
      case provisional
    }
    package let id: String
    package let track: MeetingTrackKind
    package let kind: Kind
    package let startMs: Int
    package let endMs: Int
    package let text: String
  }

  /// More confirmed characters than this close a line.
  package static let maxLineCharacters = 400
  /// More than this long without words on a track closes its line.
  package static let pauseMs = 20_000

  private struct Entry: Sendable, Equatable {
    let id: String
    let track: MeetingTrackKind
    let kind: Line.Kind
    let startMs: Int
    var endMs: Int
    var text: String
  }

  private struct Provisional: Sendable, Equatable {
    var text: String
    let startMs: Int
    var endMs: Int
    /// The confirmed line its final version belongs to.
    let lineIndex: Int
  }

  private struct TrackState: Sendable, Equatable {
    var currentLine: Int?
    /// Forces the next words onto a new line (after a discontinuity or an end).
    var lineClosed = false
    var provisional: Provisional?
    var lastWordsMs: Int?
  }

  private var entries: [Entry] = []
  private var tracks: [MeetingTrackKind: TrackState] = [:]
  private var nextID = 0

  package init() {}

  /// Applies one event of `track`'s transcript session at meeting time `atMs`.
  package mutating func apply(_ event: LiveWordsEvent, track: MeetingTrackKind, atMs: Int) {
    switch event {
    case .update(let finalized, let inProgress):
      update(track: track, finalized: finalized, inProgress: inProgress, atMs: atMs)
    case .discontinuity, .ended:
      freezeProvisional(track: track, atMs: atMs)
    }
  }

  /// Every non-empty line, in meeting order (start time, then the order lines were made).
  package var lines: [Line] {
    var shown: [(order: Int, line: Line)] = []
    for (index, entry) in entries.enumerated() {
      let text = Self.displayed(entry.text)
      guard !text.isEmpty else { continue }
      shown.append(
        (
          index,
          Line(
            id: entry.id, track: entry.track, kind: entry.kind, startMs: entry.startMs,
            endMs: entry.endMs, text: text)
        ))
    }
    for track in MeetingTrackKind.allCases {
      guard let provisional = tracks[track]?.provisional else { continue }
      let text = Self.displayed(provisional.text)
      guard !text.isEmpty else { continue }
      // Right after its own line, whatever came between.
      shown.append(
        (
          provisional.lineIndex,
          Line(
            id: "\(track.rawValue)-provisional", track: track, kind: .provisional,
            startMs: provisional.startMs, endMs: provisional.endMs, text: text)
        ))
    }
    return
      shown
      .sorted {
        ($0.line.startMs, $0.order, $0.line.kind == .provisional ? 1 : 0)
          < ($1.line.startMs, $1.order, $1.line.kind == .provisional ? 1 : 0)
      }
      .map(\.line)
  }

  // MARK: - Steps

  /// One update, in two steps. The finalized delta resolves the previous provisional suffix, so
  /// it goes to the line that suffix belonged to (or, with none pending, the open line or a new
  /// one). The new provisional suffix then stays on that line only while it is still open;
  /// when the other track spoke, the line passed the size limit or the track paused, it moves
  /// to a new line, which owns its later replacement and finalization.
  private mutating func update(
    track: MeetingTrackKind, finalized: String, inProgress: String, atMs: Int
  ) {
    var state = tracks[track] ?? TrackState()
    let prior = state.provisional
    // Closing rules measure the pause since the track's previous words: `lastWordsMs` is only
    // updated at the end of this step.

    var finalLine: Int? = prior?.lineIndex
    if !Self.isBlank(finalized) {
      if finalLine == nil {
        if let current = state.currentLine, isOpen(current, track: track, state: state, atMs: atMs) {
          finalLine = current
        } else {
          finalLine = newLine(track: track, atMs: atMs)
          state.lineClosed = false
        }
      }
      if let finalLine {
        entries[finalLine].text = Self.join(entries[finalLine].text, finalized)
        entries[finalLine].endMs = atMs
        state.currentLine = finalLine
      }
    }

    if Self.isBlank(inProgress) {
      state.provisional = nil
    } else {
      let candidate = finalLine ?? state.currentLine
      let owner: Int
      if let candidate, isOpen(candidate, track: track, state: state, atMs: atMs) {
        owner = candidate
      } else {
        owner = newLine(track: track, atMs: atMs)
        state.lineClosed = false
      }
      // The suffix keeps its first-shown time only while it stays on the same line.
      let startMs = prior?.lineIndex == owner ? (prior?.startMs ?? atMs) : atMs
      state.provisional = Provisional(
        text: inProgress, startMs: startMs, endMs: atMs, lineIndex: owner)
      state.currentLine = owner
    }

    if !Self.isBlank(finalized) || !Self.isBlank(inProgress) { state.lastWordsMs = atMs }
    tracks[track] = state
  }

  private mutating func freezeProvisional(track: MeetingTrackKind, atMs: Int) {
    guard var state = tracks[track] else { return }
    if let provisional = state.provisional, !Self.isBlank(provisional.text) {
      entries.append(
        Entry(
          id: makeID(track, "uncertain"), track: track, kind: .uncertain,
          startMs: provisional.startMs, endMs: atMs, text: provisional.text))
    }
    state.provisional = nil
    // Later words start a new line, so they never read as coming before the frozen guess.
    state.lineClosed = true
    tracks[track] = state
  }

  private func isOpen(
    _ index: Int, track: MeetingTrackKind, state: TrackState, atMs: Int
  ) -> Bool {
    guard !state.lineClosed else { return false }
    let line = entries[index]
    if line.text.count > Self.maxLineCharacters { return false }
    if let last = state.lastWordsMs, atMs - last > Self.pauseMs { return false }
    for other in MeetingTrackKind.allCases where other != track {
      if let otherWords = tracks[other]?.lastWordsMs, otherWords > line.startMs { return false }
    }
    return true
  }

  private mutating func newLine(track: MeetingTrackKind, atMs: Int) -> Int {
    entries.append(
      Entry(
        id: makeID(track, "line"), track: track, kind: .confirmed, startMs: atMs, endMs: atMs,
        text: ""))
    return entries.count - 1
  }

  private mutating func makeID(_ track: MeetingTrackKind, _ kind: String) -> String {
    nextID += 1
    return "\(track.rawValue)-\(kind)-\(nextID)"
  }

  // MARK: - Text

  private static func isBlank(_ text: String) -> Bool {
    text.allSatisfy(\.isWhitespace)
  }

  private static func displayed(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Joins two pieces, adding one space only where neither supplies one and both sides are
  /// words of a spaced script (engines differ: Whisper pieces carry their leading space, Apple's
  /// may not). Never inside Chinese, Japanese, Thai and the other unspaced scripts. The same
  /// rule as `TranscribeCppRollingSession.join` in EnviousWisprASR, which this module cannot
  /// import; change both together.
  package static func join(_ a: String, _ b: String) -> String {
    guard let last = a.last, let first = b.first else { return a + b }
    if last.isWhitespace || first.isWhitespace { return a + b }
    guard first.isLetter || first.isNumber, !isUnspaced(first), !isUnspaced(last) else {
      return a + b
    }
    return a + " " + b
  }

  private static func isUnspaced(_ character: Character) -> Bool {
    guard let scalar = character.unicodeScalars.first?.value else { return false }
    let ranges: [ClosedRange<UInt32>] = [
      0x0E00...0x0EFF, 0x1000...0x109F, 0x1780...0x17FF, 0x3000...0x30FF, 0x3400...0x4DBF,
      0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFFEF,
    ]
    return ranges.contains { $0.contains(scalar) }
  }
}
