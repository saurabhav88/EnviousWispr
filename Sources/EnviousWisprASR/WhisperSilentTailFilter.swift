import Accelerate
import EnviousWisprTranscribeCpp
import Foundation

/// #3801: removes trailing decoded segments classified as lacking sufficient acoustic support.
///
/// Whisper invents closing phrases ("Thank you.", "Sous-titrage Société Radio-Canada", "ご視聴
/// ありがとうございました") over a quiet tail. The decoder's own segment times say where each
/// sentence sits; this checks the audio there. A trailing segment is removed when it starts at
/// the real audio end while the last 250 ms is unvoiced, or when its span widened by 250 ms on
/// each side has under 120 ms of 40 ms windows above a threshold taken from the recording's own
/// loudness distribution. Never a phrase list: a spoken "thank you" sits on voice and stays.
///
/// An acoustic heuristic, not proof of silence. Genuine-word preservation is the acceptance
/// gate (measured on 1,758 recordings, plan `issue-3801-2026-10-15-whisper-trailing-hallucination.md`).
/// Every constant below is frozen to that measured rule.
enum WhisperSilentTailFilter {
  static let sampleRate = 16_000.0
  static let windowSamples = 640  // 40 ms
  static let windowMs = 40.0
  static let marginMs = 250.0
  static let minVoicedMs = 120.0
  static let afterEndToleranceMs = 40.0
  static let absoluteFloor = 0.0003

  /// `statsSamples`: the audio the loudness distribution and the voice test read, on the original
  /// timeline (batch: the full capture, never the VAD envelope slice, whose near-all-speech
  /// distribution would raise the threshold above real speech). `segmentOffsetSamples` maps the
  /// native times (decoder-input coordinates) onto it. `realEndSample` is where real audio ends on
  /// it; padding past it is never real.
  static func filter(
    _ run: TranscribeCppRunResult, statsSamples: [Float], segmentOffsetSamples: Int,
    realEndSample: Int
  ) -> (result: TranscribeCppRunResult, dropped: Int) {
    guard !statsSamples.isEmpty, !run.segments.isEmpty, segmentOffsetSamples >= 0,
      realEndSample > segmentOffsetSamples, realEndSample <= statsSamples.count
    else { return (run, 0) }

    // Complete windows only; a final partial window is ignored.
    // Widen each window to Double before Accelerate computes its mean square.
    let windowCount = statsSamples.count / windowSamples
    var widened = [Double](repeating: 0, count: windowSamples)
    var rms = [Double](repeating: 0, count: windowCount)
    statsSamples.withUnsafeBufferPointer { source in
      widened.withUnsafeMutableBufferPointer { scratch in
        for window in 0..<windowCount {
          vDSP_vspdp(
            source.baseAddress! + window * windowSamples, 1, scratch.baseAddress!, 1,
            vDSP_Length(windowSamples))
          var meanSquare = 0.0
          vDSP_measqvD(scratch.baseAddress!, 1, &meanSquare, vDSP_Length(windowSamples))
          rms[window] = meanSquare.squareRoot()
        }
      }
    }
    var sorted = rms.isEmpty ? [0.0] : rms
    vDSP_vsortD(&sorted, vDSP_Length(sorted.count), 1)  // ascending
    let p05 = sorted[sorted.count / 20]
    let p90 = sorted[Int(Double(sorted.count) * 0.9)]
    let threshold = max(2 * p05, 0.12 * p90, absoluteFloor)
    let offsetMs = Double(segmentOffsetSamples) / sampleRate * 1000
    let endMs = Double(realEndSample) / sampleRate * 1000

    /// Milliseconds of windows overlapping `[start, end)` whose RMS is strictly above threshold.
    func voicedMs(_ start: Double, _ end: Double) -> Double {
      let lower = max(0, Int(max(0, start) / 1000 / (windowMs / 1000)))
      let upper = min(rms.count, Int((max(0, end) / 1000 / (windowMs / 1000)).rounded(.up)))
      guard lower < upper else { return 0 }
      return Double(rms[lower..<upper].filter { $0 > threshold }.count) * windowMs
    }

    var segments = run.segments
    var text = trimmingTrailingWhitespace(run.text)
    var dropped = 0
    while let last = segments.last {
      // Invalid times are never evidence of silence: stop, keeping earlier removals.
      guard last.startMs >= 0, last.endMs >= last.startMs else { break }
      let start = Double(last.startMs) + offsetMs
      let end = Double(last.endMs) + offsetMs
      let unsupported =
        start >= endMs - afterEndToleranceMs
        ? voicedMs(endMs - marginMs, endMs) < minVoicedMs
        : voicedMs(max(0, min(start, endMs) - marginMs), min(endMs, end + marginMs))
          < minVoicedMs
      guard unsupported else { break }
      // The native full text is decoded separately from segment texts; cut only an exact suffix.
      let piece = last.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !piece.isEmpty, text.hasSuffix(piece) else { break }
      text.removeLast(piece.count)
      text = trimmingTrailingWhitespace(text)
      segments.removeLast()
      dropped += 1
    }
    guard dropped > 0 else { return (run, 0) }
    return (
      TranscribeCppRunResult(
        text: text, detectedLanguage: run.detectedLanguage, segments: segments),
      dropped
    )
  }

  private static func trimmingTrailingWhitespace(_ input: String) -> String {
    var text = input
    while text.last?.isWhitespace == true { text.removeLast() }
    return text
  }
}
