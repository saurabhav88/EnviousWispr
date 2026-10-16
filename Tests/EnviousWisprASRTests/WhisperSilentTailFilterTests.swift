import Foundation
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprTranscribeCpp

/// #3801: the trailing-segment acoustic check applied after every Whisper decode.
///
/// **What the user sees when this fails:** an invented "Thank you." (or a looping phrase) is
/// pasted after a dictation that ended in a pause, or a real final word they said is missing.
@Suite("Whisper silent-tail filter (#3801)", .tags(.productOutcome))
struct WhisperSilentTailFilterTests {

  // Levels are powers of two so window RMS values are exact.
  static let tone: Float = 1.0 / 1024  // room tone
  static let voice: Float = 1.0 / 32  // speech

  /// Builds audio from `(milliseconds, level)` parts; each part alternates +level/-level so a
  /// 40 ms window's RMS is exactly `level`.
  static func audio(_ parts: [(ms: Int, level: Float)]) -> [Float] {
    var samples: [Float] = []
    for part in parts {
      let count = part.ms * 16
      samples += (0..<count).map { $0 % 2 == 0 ? part.level : -part.level }
    }
    return samples
  }

  static func segment(_ startMs: Int64, _ endMs: Int64, _ text: String) -> TranscribeCppSegment {
    TranscribeCppSegment(startMs: startMs, endMs: endMs, text: text)
  }

  static func run(_ segments: [TranscribeCppSegment], language: String? = "en")
    -> TranscribeCppRunResult
  {
    TranscribeCppRunResult(
      text: segments.map(\.text).joined(separator: " "), detectedLanguage: language,
      segments: segments)
  }

  static func filter(
    _ run: TranscribeCppRunResult, _ samples: [Float], offset: Int = 0, realEnd: Int? = nil
  ) -> (result: TranscribeCppRunResult, dropped: Int) {
    WhisperSilentTailFilter.filter(
      run, statsSamples: samples, segmentOffsetSamples: offset,
      realEndSample: realEnd ?? samples.count)
  }

  /// 1 s room tone, 1.5 s speech, 1.5 s room tone.
  static let speechThenPause = audio([(1000, tone), (1500, voice), (1500, tone)])
  static let spoken = segment(1000, 2500, "Let's ship on Friday.")

  // MARK: - Removal

  @Test("an invented sentence over the trailing pause is removed and the real sentence kept")
  func silentTrailingSegmentRemoved() throws {
    let input = Self.run([Self.spoken, Self.segment(3000, 4000, "Thank you.")], language: "fr")
    let (result, dropped) = Self.filter(input, Self.speechThenPause)
    #expect(dropped == 1)
    #expect(result.text == "Let's ship on Friday.")
    #expect(result.segments == [Self.spoken])
    #expect(result.detectedLanguage == "fr")
  }

  @Test(
    "the after-end safeguard starts exactly 40 ms before the real end",
    arguments: [(Int64(3959), 0), (Int64(3960), 1)])
  func afterEndSegmentRemoved(startMs: Int64, expectedDropped: Int) {
    // A 120 ms voiced burst at 3680-3800 ms: three windows inside the ordinary widened span
    // (keeps), only two inside the after-end branch's last 250 ms (removes).
    let samples = Self.audio([
      (1000, Self.tone), (1500, Self.voice), (1180, Self.tone), (120, Self.voice), (200, Self.tone),
    ])
    let input = Self.run([Self.spoken, Self.segment(startMs, 6000, "Thank you.")])
    let (result, dropped) = Self.filter(input, samples)
    #expect(dropped == expectedDropped)
    #expect(result.text == (expectedDropped == 0 ? input.text : "Let's ship on Friday."))
    #expect(result.segments == (expectedDropped == 0 ? input.segments : [Self.spoken]))
  }

  @Test("a runaway loop of trailing inventions is removed segment by segment")
  func runawayLoopRemoved() {
    let loop = (0..<4).map { Self.segment(3000 + Int64($0) * 200, 3200 + Int64($0) * 200, "2019") }
    let (result, dropped) = Self.filter(Self.run([Self.spoken] + loop), Self.speechThenPause)
    #expect(dropped == 4)
    #expect(result.text == "Let's ship on Friday.")
    #expect(result.segments == [Self.spoken])
  }

  @Test("pure room tone with an invented sentence yields empty text")
  func allSilentYieldsEmpty() {
    let samples = Self.audio([(3000, Self.tone)])
    let (result, dropped) = Self.filter(
      Self.run([Self.segment(0, 3000, "Thank you.")]), samples)
    #expect(dropped == 1)
    #expect(result.text.isEmpty)
    #expect(result.segments.isEmpty)
  }

  @Test("digital silence after speech is treated as silence")
  func digitalZeroTail() {
    let samples = Self.audio([(1000, 0), (1500, Self.voice), (1500, 0)])
    let (result, dropped) = Self.filter(
      Self.run([Self.spoken, Self.segment(3000, 4000, "Thank you.")]), samples)
    #expect(dropped == 1)
    #expect(result.text == "Let's ship on Friday.")
  }

  // MARK: - Keeping real speech

  @Test("a spoken final sentence on voice is kept")
  func voicedTrailingSegmentKept() {
    let samples = Self.audio([(1000, Self.tone), (1500, Self.voice), (1000, Self.voice)])
    let input = Self.run([Self.spoken, Self.segment(2500, 3500, "Thank you.")])
    let (result, dropped) = Self.filter(input, samples)
    #expect(dropped == 0)
    #expect(result == input)
  }

  @Test("voice within 250 ms outside a segment's estimated span keeps it")
  func marginKeepsEarlyEndedTimestamp() {
    // Speech runs to 2650 ms; the final segment's estimate starts at 2800 ms over room tone.
    let samples = Self.audio([(1000, Self.tone), (1650, Self.voice), (1350, Self.tone)])
    let input = Self.run([Self.spoken, Self.segment(2800, 4000, "and left.")])
    #expect(Self.filter(input, samples).dropped == 0)
  }

  @Test("an after-end sentence is kept when the last 250 ms of real audio is voiced")
  func afterEndKeptWhenEndVoiced() {
    let samples = Self.audio([(1000, Self.tone), (3000, Self.voice)])
    let input = Self.run([Self.spoken, Self.segment(3990, 5000, "yes.")])
    #expect(Self.filter(input, samples).dropped == 0)
  }

  @Test("a quiet speaker's final sentence is judged against their own level")
  func quietRecordingKept() {
    let scale: Float = 1.0 / 16
    let samples = Self.audio([
      (1000, Self.tone * scale), (1500, Self.voice * scale), (1000, Self.voice * scale),
    ])
    let input = Self.run([Self.spoken, Self.segment(2500, 3500, "no.")])
    #expect(Self.filter(input, samples).dropped == 0)
  }

  @Test("a silent segment before a voiced final segment is never touched")
  func nonTrailingSilentUntouched() {
    let input = Self.run([Self.segment(0, 1000, "Okay."), Self.spoken])
    #expect(Self.filter(input, Self.speechThenPause).dropped == 0)
  }

  // MARK: - Voiced-time cutoff

  @Test(
    "under 120 ms of voice in the widened span removes; 120 ms keeps",
    arguments: [(80, 1), (120, 0)])
  func voicedCutoff(voicedMs: Int, expectedDropped: Int) {
    // Speech ends at 2500 ms; a short voiced burst of `voicedMs` starts at 3520 ms (a 40 ms
    // window boundary, so it fills exactly voicedMs / 40 windows) inside the final segment's
    // span, far from the speech.
    let samples = Self.audio([
      (1000, Self.tone), (1500, Self.voice), (1020, Self.tone), (voicedMs, Self.voice),
      (1500 - voicedMs, Self.tone),
    ])
    let input = Self.run([Self.spoken, Self.segment(3200, 4000, "Thank you.")])
    #expect(Self.filter(input, samples).dropped == expectedDropped)
  }

  @Test(
    "a window exactly at the threshold does not count as voice; one above it does",
    arguments: [(Float(2), 1), (Float(3), 0)])
  func strictThresholdComparison(multipleOfTone: Float, expectedDropped: Int) {
    // Speech at 8 x tone keeps 0.12 x p90 (0.96 x tone) below 2 x p05, so the threshold is
    // exactly 2 x tone. The final segment sits on audio at `multipleOfTone` x tone.
    let speech = Self.tone * 8
    let samples = Self.audio([
      (1000, Self.tone), (1500, speech), (500, Self.tone), (1000, Self.tone * multipleOfTone),
    ])
    let input = Self.run([Self.spoken, Self.segment(3200, 4000, "Thank you.")])
    #expect(Self.filter(input, samples).dropped == expectedDropped)
  }

  // MARK: - Stopping conditions

  @Test("a segment whose text is not the text's suffix stops removal; earlier removals stand")
  func suffixMismatchStops() {
    // Sits on room tone (so only the suffix check can stop it); the text says "bye." not "Bye.".
    let mismatched = Self.segment(3000, 3100, "Bye.")
    let invented = Self.segment(3200, 4000, "Thank you.")
    let input = TranscribeCppRunResult(
      text: "Let's ship on Friday. Bye bye. Thank you.", detectedLanguage: "en",
      segments: [Self.spoken, mismatched, invented])
    let (result, dropped) = Self.filter(input, Self.speechThenPause)
    #expect(dropped == 1)
    #expect(result.text == "Let's ship on Friday. Bye bye.")
    #expect(result.segments == [Self.spoken, mismatched])
  }

  @Test(
    "invalid segment times stop removal; earlier removals stand",
    arguments: [(Int64(-1), Int64(3000)), (Int64(3000), Int64(2900))])
  func invalidTimesStop(startMs: Int64, endMs: Int64) {
    let invalid = Self.segment(startMs, endMs, "Hm.")
    let invented = Self.segment(3200, 4000, "Thank you.")
    let (result, dropped) = Self.filter(
      Self.run([Self.spoken, invalid, invented]), Self.speechThenPause)
    #expect(dropped == 1)
    #expect(result.segments == [Self.spoken, invalid])
    #expect(result.text == "Let's ship on Friday. Hm.")
  }

  @Test("no segments or no audio returns the input unchanged")
  func emptyInputsUnchanged() {
    let empty = TranscribeCppRunResult(text: "", detectedLanguage: nil, segments: [])
    #expect(Self.filter(empty, Self.speechThenPause).dropped == 0)
    let input = Self.run([Self.segment(0, 1000, "Thank you.")])
    #expect(Self.filter(input, []).result == input)
  }

  // MARK: - Timeline

  @Test("segment times are mapped through the envelope offset onto the full capture")
  func offsetMapsOntoFullCapture() {
    // Decoder input starts 1000 ms into the capture (the VAD envelope), so native times are
    // relative to it. Statistics still cover the full capture, room tone included.
    let input = Self.run([
      Self.segment(0, 1500, "Let's ship on Friday."), Self.segment(2000, 3000, "Thank you."),
    ])
    let (result, dropped) = Self.filter(
      input, Self.speechThenPause, offset: 16_000, realEnd: Self.speechThenPause.count)
    #expect(dropped == 1)
    #expect(result.text == "Let's ship on Friday.")
  }

  @Test("audio past the real end never counts as voice")
  func realEndBeforeCaptureEnd() {
    // Real audio ends at 4000 ms; 1 s of loud samples follows on the same buffer.
    let samples = Self.speechThenPause + Self.audio([(1000, Self.voice)])
    let input = Self.run([Self.spoken, Self.segment(3000, 4000, "Thank you.")])
    let (_, dropped) = Self.filter(input, samples, realEnd: Self.speechThenPause.count)
    #expect(dropped == 1)
  }

  @Test("a trailing partial window cannot supply the third voiced window")
  func partialWindowIgnored() {
    // Two complete voiced windows (80 ms) end the complete-window audio; 300 loud samples after
    // them never form a window. Counting that partial window would reach 120 ms and keep it.
    let samples =
      Self.audio([(1000, Self.tone), (1500, Self.voice), (1420, Self.tone), (80, Self.voice)])
      + [Float](repeating: Self.voice, count: 300)
    let (result, dropped) = Self.filter(
      Self.run([Self.spoken, Self.segment(3000, 4018, "Thank you.")]), samples)
    #expect(dropped == 1)
    #expect(result.text == "Let's ship on Friday.")
    #expect(result.segments == [Self.spoken])
  }
}
