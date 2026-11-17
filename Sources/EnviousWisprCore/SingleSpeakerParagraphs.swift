import Foundation

/// Paragraph turns for an imported transcript with one voice (#4611 T4, founder 2026-11-16):
/// a one-speaker transcript keeps a start time per natural paragraph, never one per sentence,
/// so its page can play from a paragraph the way a meeting plays from a turn.
///
/// A paragraph ends only where the speaker pauses for at least `breakPauseMs` at the end of a
/// sentence, and only once it holds at least `minimumWords` words. A stretch with no such pause
/// ends at the first sentence end after `forcedBreakMs`; a paragraph never breaks mid-sentence
/// or beside text the timings do not place. The values are the founder-approved starting point
/// (#4611 transcript T1-T9 review) and are expected to be tuned on real recordings.
///
/// Every paragraph is one `Turn` with `speakerID`, so storage, cleanup, Marked up and export
/// treat it like any speaker turn. Returns nil when the timings cannot place the text (mostly
/// untimed words, an untimed segment, out-of-order ranges): such a transcript stays one plain
/// document, as before.
public enum SingleSpeakerParagraphs {
  /// The one speaker of a single-voice transcript. Not a diarizer id; readers that draw
  /// speakers leave it unnamed.
  public static let speakerID = "single"

  public static let breakPauseMs = 2_500
  public static let minimumWords = 40
  public static let forcedBreakMs = 120_000
  /// How long the word before a pause takes, roughly. Parakeet's word times run each word up
  /// to the next one, so a silence shows only as a late next start (measured 2026-11-17 on two
  /// 3.2 s pauses: the longest end-to-start gap was 160 ms, and start-to-next-start less 600 ms
  /// read 2,840 and 2,760 ms, so the word itself took about 250 ms). A word pause is therefore
  /// the time from the last spoken word's start to the next start, less this.
  static let spokenWordMs = 300

  /// One stretch of the text: a word (word timings) or a segment (segment timings). An untimed
  /// word has no times and never sits on either side of a paragraph break.
  struct Unit: Equatable {
    let range: Range<Int>
    let startMs: Int?
    let endMs: Int?
  }

  /// From word timings (Parakeet).
  public static func paragraphs(words: [ASRWordTiming], rawText: String) -> [Turn]? {
    // A transcript whose words are mostly untimed (a space-free script maps to one untimed
    // entry) has no paragraph times to give.
    let timed = words.filter { $0.startMs != nil && $0.endMs != nil }.count
    guard !words.isEmpty, timed * 5 >= words.count * 4 else { return nil }
    let units = words.map { word -> Unit in
      guard let start = word.startMs, let end = word.endMs else {
        return Unit(range: word.range, startMs: nil, endMs: nil)
      }
      return Unit(range: word.range, startMs: start, endMs: max(start, end))
    }
    return paragraphs(units: units, rawText: rawText, granularity: .word)
  }

  /// From segment timings (an engine with no word timing).
  public static func paragraphs(segments: [ASRSegmentTiming], rawText: String) -> [Turn]? {
    var units: [Unit] = []
    for segment in segments {
      guard segment.hasUsableBounds, let start = segment.startMs, let end = segment.endMs else {
        return nil
      }
      units.append(Unit(range: segment.range, startMs: start, endMs: max(start, end)))
    }
    return paragraphs(units: units, rawText: rawText, granularity: .segment)
  }

  static func paragraphs(units: [Unit], rawText: String, granularity: TurnGranularity) -> [Turn]? {
    let text = Array(rawText.utf16)
    guard !units.isEmpty else { return nil }
    // Units must be in order and inside the text; anything else cannot be placed safely.
    var cursor = 0
    for unit in units {
      guard unit.range.lowerBound >= cursor, unit.range.upperBound <= text.count,
        !unit.range.isEmpty
      else { return nil }
      cursor = unit.range.upperBound
    }

    // Indices of the units that start a paragraph. A break needs both neighbours timed and
    // nothing but whitespace between them, so it never lands inside text the timings do not
    // place (an untimed word, or text no segment covered).
    var starts = [0]
    var words = wordCount(text, units[0].range)
    var paragraphStartMs = units[0].startMs
    // The pause is measured from the end of the last unit with speech in it: Parakeet times a
    // sentence's closing punctuation as its own token, which can stretch over the silence.
    var lastSpeechEndMs = hasSpeech(text, units[0].range) ? units[0].endMs : nil
    var lastSpeechStartMs = hasSpeech(text, units[0].range) ? units[0].startMs : nil
    for index in 1..<units.count {
      let previous = units[index - 1]
      let unit = units[index]
      if paragraphStartMs == nil { paragraphStartMs = previous.startMs }
      if let previousEnd = previous.endMs, let start = unit.startMs,
        onlyWhitespace(text, previous.range.upperBound, unit.range.lowerBound),
        endsSentence(text, previous.range),
        // With the last spoken word untimed, the silence before this unit is unknown.
        granularity == .segment || lastSpeechEndMs != nil
      {
        var pause = start - (lastSpeechEndMs ?? previousEnd)
        if granularity == .word, let spokenStart = lastSpeechStartMs {
          pause = max(pause, start - spokenStart - spokenWordMs)
        }
        let elapsed = previousEnd - (paragraphStartMs ?? previousEnd)
        let natural = pause >= breakPauseMs && words >= minimumWords
        // A stretch with no long pause ends at the first sentence end after two minutes.
        let forced = elapsed >= forcedBreakMs
        if natural || forced {
          starts.append(index)
          words = 0
          paragraphStartMs = start
        }
      }
      words += wordCount(text, unit.range)
      if hasSpeech(text, unit.range) {
        // Untimed speech leaves no known silence after the last timed word: forget it, so no
        // pause is inferred across words whose times are unknown.
        lastSpeechEndMs = unit.endMs
        lastSpeechStartMs = unit.startMs
      }
    }

    // Paragraph ranges partition the text so no words are dropped; each is then trimmed.
    var turns: [Turn] = []
    for (n, first) in starts.enumerated() {
      let last = n + 1 < starts.count ? starts[n + 1] - 1 : units.count - 1
      let lower = n == 0 ? 0 : units[first].range.lowerBound
      let upper = n + 1 < starts.count ? units[starts[n + 1]].range.lowerBound : text.count
      guard let range = trimmed(text, lower, upper) else { continue }
      let members = units[first...last]
      turns.append(
        Turn(
          id: "\(range.lowerBound)-\(range.upperBound)", speakerId: speakerID,
          startMs: members.compactMap(\.startMs).min(), endMs: members.compactMap(\.endMs).max(),
          originalTextRange: range, granularity: granularity))
    }
    return turns.isEmpty ? nil : turns
  }

  /// Numbers only, for the local log: the five longest pauses between timed units (measured as
  /// the paragraph rule measures a word pause), each with
  /// whether the unit before it ends a sentence and holds speech. No text.
  public static func gapSummary(words: [ASRWordTiming], rawText: String) -> String {
    let text = Array(rawText.utf16)
    var gaps: [(ms: Int, end: Bool, speech: Bool)] = []
    for index in 1..<max(1, words.count) {
      let a = words[index - 1]
      let b = words[index]
      guard let end = a.endMs, let start = b.startMs, a.range.upperBound <= text.count else {
        continue
      }
      let fromStart = a.startMs.map { start - $0 - spokenWordMs } ?? 0
      gaps.append((max(start - end, fromStart), endsSentence(text, a.range), hasSpeech(text, a.range)))
    }
    let top = gaps.sorted { $0.ms > $1.ms }.prefix(5)
    return top.map { "\($0.ms)\($0.end ? "E" : "")\($0.speech ? "" : "P")" }.joined(separator: ",")
  }

  /// Whether the unit holds a letter or digit (not only punctuation or space).
  static func hasSpeech(_ text: [UInt16], _ range: Range<Int>) -> Bool {
    String(decoding: text[range], as: UTF16.self).unicodeScalars.contains {
      CharacterSet.alphanumerics.contains($0)
    }
  }

  static func onlyWhitespace(_ text: [UInt16], _ lower: Int, _ upper: Int) -> Bool {
    guard lower < upper else { return true }
    return text[lower..<upper].allSatisfy(isWhitespace)
  }

  private static let sentenceEnders: Set<UInt16> = Set(".?!…。？！".utf16)
  private static let closers: Set<UInt16> = Set("\"'”’)]»」』".utf16)

  /// Whether the unit's text ends a sentence (closing quotes and brackets are skipped).
  static func endsSentence(_ text: [UInt16], _ range: Range<Int>) -> Bool {
    var index = range.upperBound - 1
    while index >= range.lowerBound {
      let unit = text[index]
      if isWhitespace(unit) || closers.contains(unit) {
        index -= 1
        continue
      }
      return sentenceEnders.contains(unit)
    }
    return false
  }

  /// Words that start inside the range. A unit can be part of a word (Parakeet times sub-word
  /// tokens), so a range that continues the word before it adds nothing.
  static func wordCount(_ text: [UInt16], _ range: Range<Int>) -> Int {
    var count = 0
    var inWord = range.lowerBound > 0 && !isWhitespace(text[range.lowerBound - 1])
    for index in range {
      if isWhitespace(text[index]) {
        inWord = false
      } else if !inWord {
        inWord = true
        count += 1
      }
    }
    return count
  }

  private static func trimmed(_ text: [UInt16], _ lower: Int, _ upper: Int) -> Range<Int>? {
    var low = lower
    var high = upper
    while low < high, isWhitespace(text[low]) { low += 1 }
    while high > low, isWhitespace(text[high - 1]) { high -= 1 }
    return low < high ? low..<high : nil
  }

  private static func isWhitespace(_ unit: UInt16) -> Bool {
    unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D || unit == 0xA0 || unit == 0x3000
  }
}
