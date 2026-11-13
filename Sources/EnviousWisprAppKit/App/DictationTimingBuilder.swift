import CryptoKit
import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprStorage
import Foundation

/// Builds the timing sidecar of one saved dictation recording (#3147 §3.2): the delivering
/// decode's untouched text, its identity, and one anchor per sentence whose start and end the
/// speech engine actually timed, placed on the recording's own timeline.
///
/// Only a Parakeet batch decode (ordinary, streaming rescue, lead-trim salvage or Phase 2 retry)
/// over the conditioned batch buffer can carry anchors. Whisper and a Parakeet streaming win stay
/// untimed. Nothing is estimated: a sentence whose first or last word has no timing, or whose
/// start or end falls outside the audio the decode shared with the recording (padding), gets no
/// anchor, and evidence that does not agree with itself (words that are not the text, an
/// unordered or out-of-recording map) gives no anchors at all.
enum DictationTimingBuilder {
  static func timing(
    for asr: DictationASREvidence, recordingSampleCount: Int
  ) -> RecordingTiming {
    RecordingTiming(
      exactASRText: asr.text, textVersion: textVersion(of: asr.text),
      anchors: anchors(for: asr, recordingSampleCount: recordingSampleCount))
  }

  /// Identity of the text the anchors index, so they are never applied to another version.
  static func textVersion(of text: String) -> String {
    let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    return "asr-sha256:\(digest)"
  }

  // MARK: - Anchors

  static func anchors(
    for asr: DictationASREvidence, recordingSampleCount: Int
  ) -> [RecordingTiming.Anchor] {
    guard let evidence = asr.timing, isTimedDecode(asr), evidence.sampleRate > 0,
      recordingSampleCount > 0,
      let map = RecordingMap(evidence.timeline, recordingSampleCount: recordingSampleCount),
      let words = verifiedWords(evidence.words, text: asr.text)
    else { return [] }

    var anchors: [RecordingTiming.Anchor] = []
    for sentence in sentences(of: words) {
      guard let first = sentence.first, let last = sentence.last,
        let startMs = first.startMs, let endMs = last.endMs, startMs >= 0, endMs > startMs,
        let startDecode = sample(atMs: startMs, sampleRate: evidence.sampleRate),
        let endDecode = sample(atMs: endMs, sampleRate: evidence.sampleRate),
        let start = map.recordingSample(forStart: startDecode),
        let end = map.recordingSample(forEnd: endDecode), end > start
      else { continue }
      // Engine times run forward; a sentence that would start before the previous one ended
      // is ambiguous, so it stays untimed rather than overlapping its neighbour.
      if let previous = anchors.last,
        Double(start) / Double(evidence.sampleRate) < previous.endSeconds
      {
        continue
      }
      let rate = Double(evidence.sampleRate)
      anchors.append(
        RecordingTiming.Anchor(
          utf16Start: first.range.lowerBound, utf16End: last.range.upperBound,
          startSeconds: Double(start) / rate, endSeconds: Double(end) / rate))
    }
    return anchors
  }

  /// The decodes whose word timings sit on the conditioned batch buffer's timeline. Engine
  /// identity is read here, outside the kernel, on purpose: anchors are a Parakeet-batch
  /// product, and any other engine or source stays untimed.
  private static func isTimedDecode(_ asr: DictationASREvidence) -> Bool {
    guard asr.backend == .parakeet else { return false }
    switch asr.source {
    case .batch, .batchRescue, .leadSalvage, .phase2Retry: break
    case .streaming: return false
    }
    switch asr.input {
    case .conditionedBatch, .conditionedBatchTrimmed: return true
    case .rawCapture, .paddedRawCapture: return false
    }
  }

  /// The words, if they really are the delivering text: in order, non-overlapping, inside the
  /// text, each one exactly the text it claims. Any disagreement means the timings belong to
  /// some other text, so none are used.
  private static func verifiedWords(_ words: [ASRWordTiming], text: String) -> [ASRWordTiming]? {
    let utf16 = text.utf16
    var previousEnd = 0
    for word in words {
      guard word.range.lowerBound >= previousEnd, word.range.upperBound <= utf16.count,
        !word.range.isEmpty
      else { return nil }
      let lower = utf16.index(utf16.startIndex, offsetBy: word.range.lowerBound)
      let upper = utf16.index(utf16.startIndex, offsetBy: word.range.upperBound)
      guard let slice = String(utf16[lower..<upper]), slice == word.word else { return nil }
      previousEnd = word.range.upperBound
    }
    return words.isEmpty ? nil : words
  }

  /// Splits the words into sentences: a sentence ends at a word whose last letter, after any
  /// closing quotes or brackets, is sentence-final punctuation. The text is never re-tokenized:
  /// boundaries fall only between the engine-bound words, so an anchor always starts and ends
  /// exactly on a timed word.
  static func sentences(of words: [ASRWordTiming]) -> [[ASRWordTiming]] {
    var result: [[ASRWordTiming]] = []
    var current: [ASRWordTiming] = []
    for word in words {
      current.append(word)
      if endsSentence(word.word) {
        result.append(current)
        current = []
      }
    }
    if !current.isEmpty { result.append(current) }
    return result
  }

  private static let closers: Set<Character> = [
    ")", "]", "}", "\"", "'", "\u{201D}", "\u{2019}", "\u{00BB}", "\u{203A}",
  ]
  private static let terminators: Set<Character> = [
    ".", "!", "?", "\u{2026}", "\u{203C}", "\u{2047}", "\u{2048}", "\u{2049}", "\u{3002}",
    "\u{FF01}", "\u{FF1F}",
  ]

  private static func endsSentence(_ word: String) -> Bool {
    var characters = Substring(word)
    while let last = characters.last, closers.contains(last) { characters = characters.dropLast() }
    guard let last = characters.last else { return false }
    return terminators.contains(last)
  }

  /// Milliseconds to a sample index on the decode input; nil on overflow.
  private static func sample(atMs ms: Int, sampleRate: Int) -> Int? {
    let (product, overflow) = ms.multipliedReportingOverflow(by: sampleRate)
    return overflow ? nil : product / 1000
  }

  /// The decode-input-to-recording map, accepted only when it is ordered and lies wholly
  /// inside the recording.
  struct RecordingMap {
    let spans: [DictationAudioTimelineSpan]

    init?(_ spans: [DictationAudioTimelineSpan], recordingSampleCount: Int) {
      guard !spans.isEmpty else { return nil }
      var previousDecodeEnd = 0
      var previousRecordingEnd = 0
      for span in spans {
        let count = span.decodeRange.count
        let (recordingEnd, overflow) = span.recordingStartSample.addingReportingOverflow(count)
        guard count > 0, span.decodeRange.lowerBound >= previousDecodeEnd,
          span.recordingStartSample >= previousRecordingEnd, !overflow,
          recordingEnd <= recordingSampleCount
        else { return nil }
        previousDecodeEnd = span.decodeRange.upperBound
        previousRecordingEnd = recordingEnd
      }
      self.spans = spans
    }

    /// The recording sample a passage starting at decode sample `s` starts at: `s` must be a
    /// real sample of a mapped stretch.
    func recordingSample(forStart s: Int) -> Int? {
      guard let span = spans.first(where: { $0.decodeRange.contains(s) }) else { return nil }
      return span.recordingStartSample + (s - span.decodeRange.lowerBound)
    }

    /// The recording sample a passage ending at decode sample `e` (exclusive) ends at: the
    /// sample before `e` must be a real sample of a mapped stretch.
    func recordingSample(forEnd e: Int) -> Int? {
      guard
        let span = spans.first(where: {
          e > $0.decodeRange.lowerBound && e <= $0.decodeRange.upperBound
        })
      else { return nil }
      return span.recordingStartSample + (e - span.decodeRange.lowerBound)
    }
  }
}
