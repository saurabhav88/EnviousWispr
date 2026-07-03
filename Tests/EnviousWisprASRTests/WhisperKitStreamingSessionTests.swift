import EnviousWisprCore
import Foundation
import Testing
@preconcurrency import WhisperKit

@testable import EnviousWisprASR

// MARK: - WhisperKitStreamingSessionTests (#1276 Step 2, PR-2)
//
// The streaming session's correctness spine: it decodes ONE growing stream
// against itself (confirmed-segment holdback) and flushes ONE tail over the SAME
// buffer, so neither meshing bug can occur by construction. These tests pin:
//   - single-coordinate: the flush reads the session's own `streamingPCM` (via
//     the retained provider), NEVER the `finalSamples` parameter (the r1/r2
//     blocker — the earliest failure point);
//   - confirmation holdback (freeze count-N segments, advance lastConfirmedSec);
//   - zero-meshing on adversarial overlapping cycles;
//   - the hallucination-tail gate (skip a near-silence tail);
//   - cleanup-once (cancel doesn't leak / double-flush).

@Suite struct WhisperKitStreamingSessionTests {

  // MARK: Fakes

  /// Scripted fake decoder — returns each entry in order, one per `transcribe`
  /// call. Records every `audioArray` it was handed so a test can prove WHICH
  /// buffer the flush decoded (single-coordinate assertion).
  private struct FakeDecodeError: Error {}

  private actor FakeDecoder: WhisperKitTranscribing {
    private var scripted: [[TranscriptionResult]]
    /// Call index (0-based) on which `transcribe` throws instead of returning.
    private let throwOnCall: Int?
    private(set) var callCount = 0
    private(set) var lastAudioArray: [Float] = []
    private(set) var seenAudioCounts: [Int] = []

    init(scripted: [[TranscriptionResult]], throwOnCall: Int? = nil) {
      self.scripted = scripted
      self.throwOnCall = throwOnCall
    }

    func transcribe(audioArray: [Float], decodeOptions: DecodingOptions?) async throws
      -> [TranscriptionResult]
    {
      let index = callCount
      callCount += 1
      if index == throwOnCall { throw FakeDecodeError() }
      lastAudioArray = audioArray
      seenAudioCounts.append(audioArray.count)
      guard index < scripted.count else { return [] }
      return scripted[index]
    }
  }

  private func seg(_ start: Float, _ end: Float, _ text: String) -> TranscriptionSegment {
    TranscriptionSegment(start: start, end: end, text: text)
  }

  private func result(_ text: String, _ segments: [TranscriptionSegment]) -> TranscriptionResult {
    TranscriptionResult(
      text: text, segments: segments, language: "en", timings: TranscriptionTimings())
  }

  private func session(
    _ scripted: [[TranscriptionResult]], N: Int = 2
  ) -> (WhisperKitStreamingSession, FakeDecoder) {
    let fake = FakeDecoder(scripted: scripted)
    let s = WhisperKitStreamingSession(
      whisperKit: fake, decodingOptions: DecodingOptions(),
      requiredSegmentsForConfirmation: N, cadence: .milliseconds(1))
    return (s, fake)
  }

  private func fixedProvider(_ samples: [Float])
    -> @Sendable () async -> (samples: [Float], count: Int)
  {
    { (samples: samples, count: samples.count) }
  }

  // MARK: SINGLE-COORDINATE (the r1/r2 blocker)

  @Test("flush decodes the session's own streamingPCM, NOT the finalSamples parameter")
  func flushIgnoresFinalSamples() async throws {
    // Loop decode confirms nothing (only 1 segment < N); flush tail carries the text.
    let (s, fake) = session([[result("hello world", [seg(0, 2, "hello world")])]])
    // Provider returns 3s of a recognizable value; finalSamples is deliberately
    // garbage. If the flush read finalSamples, it would decode the wrong buffer.
    let streamPCM = [Float](repeating: 0.5, count: 48_000)  // 3s @ 16k
    await s.start(audioSamplesProvider: fixedProvider(streamPCM))
    let r = await s.finalize(finalSamples: [Float](repeating: -9.0, count: 5), speechSegments: [])
    #expect(r.accepted)
    #expect(r.text == "hello world")
    // The decoder's last call must have seen the 48k streamPCM, never the 5-sample garbage.
    let seen = await fake.lastAudioArray
    #expect(seen.count == 48_000, "flush decoded streamingPCM (48000), not finalSamples")
    #expect(seen.first == Float(0.5))
  }

  // MARK: Confirmation holdback

  @Test("confirmation freezes count-N segments and advances lastConfirmedSec")
  func confirmationHoldback() async throws {
    // One decode returns 4 segments; with N=2, the first 2 confirm, lastConfirmedSec
    // advances to segment[1].end (2.0). The trailing 2 stay unconfirmed.
    let segs = [seg(0, 1, "one"), seg(1, 2, "two"), seg(2, 3, "three"), seg(3, 4, "four")]
    let (s, _) = session([[result("one two three four", segs)]], N: 2)
    let pcm = [Float](repeating: 0.3, count: 64_000)  // 4s, > 1s gate
    await s.start(audioSamplesProvider: fixedProvider(pcm))
    await waitForDecode(1, s)
    let confirmed = await s.confirmedTextForTests
    let lastSec = await s.lastConfirmedSecForTests
    #expect(confirmed == "one two", "first count-N segments confirmed")
    #expect(lastSec == 2.0, "lastConfirmedSec advanced to segment[1].end")
    await s.cancel()
  }

  // MARK: Zero-meshing (adversarial)

  @Test("no mid-phrase duplication across confirmed prefix + flush tail")
  func zeroMeshing() async throws {
    // Cycle 1 confirms "check the numbers" (2 of 4 segments, N=2). Flush re-decodes
    // from lastConfirmedSec and returns ONLY the uncovered tail — never re-emitting
    // the confirmed phrase. A stitch design would double "the numbers"; this cannot.
    let cycle = result(
      "check the numbers in the spreadsheet",
      [seg(0, 1, "check the"), seg(1, 2, "numbers"), seg(2, 3, "in the"), seg(3, 4, "spreadsheet")])
    let tail = result(
      "in the spreadsheet before I send it",
      [seg(2, 3, "in the spreadsheet"), seg(3, 5, "before I send it")])
    let (s, _) = session([[cycle], [tail]], N: 2)
    let pcm = [Float](repeating: 0.4, count: 96_000)  // 6s
    await s.start(audioSamplesProvider: fixedProvider(pcm))
    await waitForDecode(1, s)
    let r = await s.finalize(finalSamples: [], speechSegments: [])
    let text = r.text ?? ""
    // "check the numbers" appears exactly once (confirmed), tail adds the rest.
    let occurrences = text.components(separatedBy: "check the").count - 1
    #expect(occurrences == 1, "confirmed phrase not duplicated: \(text)")
    #expect(text.contains("before I send it"), "tail appended: \(text)")
  }

  // MARK: Hallucination-tail gate

  @Test("flush skips the tail decode when the uncovered tail is below the minimum voiced duration")
  func hallucinationTailGate() async throws {
    // With N=2 the first 2 of 4 segments confirm, so `lastConfirmedSec` = seg[1].end
    // = 3.8. The buffer is 4.0s, so the uncovered tail is 0.2s (< 0.4s min) → the
    // flush must NOT run a tail decode (only the loop decode ran).
    let segs = [seg(0, 2, "a"), seg(2, 3.8, "b"), seg(3.8, 3.9, "c"), seg(3.9, 4.0, "d")]
    let (s, fake) = session([[result("a b c d", segs)]], N: 2)
    let pcm = [Float](repeating: 0.3, count: 64_000)  // 4.0s
    await s.start(audioSamplesProvider: fixedProvider(pcm))
    await waitForDecode(1, s)
    let callsBefore = await fake.callCount
    let r = await s.finalize(finalSamples: [], speechSegments: [])
    let callsAfter = await fake.callCount
    #expect(callsAfter == callsBefore, "no tail decode for a sub-minimum uncovered tail")
    #expect(r.text == "a b", "confirmed text returned as-is (segments c/d unconfirmed and dropped)")
  }

  // MARK: Flush failure forces fallback (Codex r1 P2)

  @Test(
    "flush tail decode throwing after a confirmed prefix returns accepted=false (forces batch fallback)"
  )
  func flushThrowForcesFallback() async throws {
    // Cycle 0 confirms a prefix (4 segments, N=2 -> confirm "one two"); cycle 1 is
    // the flush tail decode, which THROWS. Even though a non-empty prefix exists,
    // the result must be accepted=false so the adapter re-transcribes the COMPLETE
    // audio via the clean batch fallback (not ship a truncated prefix).
    let segs = [seg(0, 1, "one"), seg(1, 2, "two"), seg(2, 3, "three"), seg(3, 5, "four")]
    let fake = FakeDecoder(scripted: [[result("one two three four", segs)]], throwOnCall: 1)
    let s = WhisperKitStreamingSession(
      whisperKit: fake, decodingOptions: DecodingOptions(),
      requiredSegmentsForConfirmation: 2, cadence: .milliseconds(1))
    let pcm = [Float](repeating: 0.4, count: 96_000)  // 6s — tail well above the gate
    await s.start(audioSamplesProvider: fixedProvider(pcm))
    await waitForDecode(1, s)
    let confirmed = await s.confirmedTextForTests
    #expect(confirmed == "one two", "prefix was confirmed before the flush")
    let r = await s.finalize(finalSamples: [], speechSegments: [])
    #expect(!r.accepted, "flush-failure result must be rejected so the adapter falls back to batch")
    #expect(r.strategy == "streaming_flush_failed")
  }

  @Test(
    "a voiced tail that decodes to empty returns accepted=false (forces batch fallback, Codex r2 P2)"
  )
  func emptyTailForcesFallback() async throws {
    // Cycle 0 confirms "one two"; the flush tail decode (cycle 1) succeeds but
    // returns EMPTY text over a voiced tail (audio present, passes the energy
    // gate). Shipping the prefix would drop the ending, so accepted=false forces
    // the adapter to re-transcribe the complete audio via batch.
    let segs = [seg(0, 1, "one"), seg(1, 2, "two"), seg(2, 3, "three"), seg(3, 5, "four")]
    let fake = FakeDecoder(scripted: [[result("one two three four", segs)], [result("", [])]])
    let s = WhisperKitStreamingSession(
      whisperKit: fake, decodingOptions: DecodingOptions(),
      requiredSegmentsForConfirmation: 2, cadence: .milliseconds(1))
    let pcm = [Float](repeating: 0.4, count: 96_000)  // 6s voiced tail (RMS 0.4 > floor)
    await s.start(audioSamplesProvider: fixedProvider(pcm))
    await waitForDecode(1, s)
    let r = await s.finalize(finalSamples: [], speechSegments: [])
    #expect(!r.accepted, "empty voiced-tail decode must be rejected (no truncated prefix)")
    #expect(r.strategy == "streaming_tail_empty_fallback")
  }

  @Test("a short/quiet tail is skipped and the confirmed prefix is accepted as complete")
  func quietTailAcceptsPrefix() async throws {
    // Confirmed prefix "one two"; the uncovered tail is voiced-duration-long but
    // near-silent (RMS below the floor), so it is genuine trailing silence — skip
    // the tail decode and accept the prefix (preserve the streaming speed win, no
    // needless re-batch).
    let segs = [seg(0, 1, "one"), seg(1, 2, "two"), seg(2, 3, "three"), seg(3, 5, "four")]
    let cycle = result("one two three four", segs)
    // Loud confirmed region then a quiet tail: first 2s at 0.4, then 4s near-zero.
    var pcm = [Float](repeating: 0.4, count: 32_000)
    pcm += [Float](repeating: 0.0001, count: 64_000)  // quiet tail (RMS ~0.0001 < floor)
    let fake = FakeDecoder(scripted: [[cycle]])
    let s = WhisperKitStreamingSession(
      whisperKit: fake, decodingOptions: DecodingOptions(),
      requiredSegmentsForConfirmation: 2, cadence: .milliseconds(1))
    await s.start(audioSamplesProvider: fixedProvider(pcm))
    await waitForDecode(1, s)
    let callsBefore = await fake.callCount
    let r = await s.finalize(finalSamples: [], speechSegments: [])
    let callsAfter = await fake.callCount
    #expect(callsAfter == callsBefore, "quiet tail is not decoded")
    #expect(r.accepted, "confirmed prefix accepted as the complete transcript")
    #expect(r.text == "one two")
  }

  // MARK: Cleanup-once

  @Test("cancel stops the loop and a subsequent finalize does not decode")
  func cancelThenFinalizeIsInert() async throws {
    let (s, fake) = session([[result("x", [seg(0, 2, "x")])]], N: 2)
    let pcm = [Float](repeating: 0.2, count: 48_000)
    await s.start(audioSamplesProvider: fixedProvider(pcm))
    await s.cancel()
    let callsAfterCancel = await fake.callCount
    let r = await s.finalize(finalSamples: [], speechSegments: [])
    let callsAfterFinalize = await fake.callCount
    // finalize after cancel: provider was dropped, so no flush decode runs.
    #expect(callsAfterFinalize == callsAfterCancel, "no decode after cancel")
    #expect(r.text == nil || r.text?.isEmpty == true, "no transcript after cancel")
  }

  // MARK: Helpers

  private func waitForDecode(_ n: Int, _ s: WhisperKitStreamingSession) async {
    while await s.currentDecodeCount < n { await Task.yield() }
  }
}
