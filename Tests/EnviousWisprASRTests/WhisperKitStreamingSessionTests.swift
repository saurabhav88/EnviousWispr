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
    nonisolated func encodeText(_ text: String) -> [Int] { [] }
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
    // The decoder's last call must have seen the 48k streamPCM (plus the 0.5s
    // trailing-silence flush padding = 8000 samples), never the 5-sample garbage.
    let seen = await fake.lastAudioArray
    #expect(seen.count == 48_000 + 8_000, "flush decoded padded streamingPCM, not finalSamples")
    #expect(seen.first == Float(0.5), "leading samples are the real audio, not garbage")
    #expect(seen.last == Float(0), "trailing silence padding applied for last-word context")
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

  // MARK: Tail gate

  @Test("flush skips the tail decode for a negligibly-short (sub-100ms) tail")
  func negligibleTailSkipped() async throws {
    // With N=2 the first 2 of 4 segments confirm, so `lastConfirmedSec` = seg[1].end
    // = 3.95. The buffer is 4.0s, so the uncovered tail is 0.05s (< 100ms) → too
    // short to carry a word → skip the tail decode, accept the prefix.
    let segs = [seg(0, 2, "a"), seg(2, 3.95, "b"), seg(3.95, 3.97, "c"), seg(3.97, 4.0, "d")]
    let (s, fake) = session([[result("a b c d", segs)]], N: 2)
    let pcm = [Float](repeating: 0.3, count: 64_000)  // 4.0s
    await s.start(audioSamplesProvider: fixedProvider(pcm))
    await waitForDecode(1, s)
    let callsBefore = await fake.callCount
    let r = await s.finalize(finalSamples: [], speechSegments: [])
    let callsAfter = await fake.callCount
    #expect(callsAfter == callsBefore, "no tail decode for a sub-100ms tail")
    #expect(r.text == "a b", "confirmed prefix accepted as complete")
  }

  @Test("a SHORT but voiced tail (150-400ms) is decoded, not dropped (Codex r6 P2)")
  func shortVoicedTailIsDecoded() async throws {
    // Confirmed prefix "one two" (lastConfirmedSec = seg[1].end = 3.8). The buffer
    // is 4.05s → a 0.25s VOICED tail. Under the old 0.4s duration gate this was
    // skipped and the prefix accepted, silently dropping a real final word. Now it
    // is decoded (energy is the silence signal, not duration): the flush tail
    // returns "yes" and it is appended.
    let cycle = result(
      "one two three four",
      [seg(0, 1, "one"), seg(1, 2, "two"), seg(2, 3, "three"), seg(3, 3.8, "four")])
    let tail = result("yes", [seg(3.8, 4.05, "yes")])
    let (s, fake) = session([[cycle], [tail]], N: 2)
    let pcm = [Float](repeating: 0.4, count: 64_800)  // 4.05s voiced (RMS 0.4 > floor)
    await s.start(audioSamplesProvider: fixedProvider(pcm))
    await waitForDecode(1, s)
    let callsBefore = await fake.callCount
    let r = await s.finalize(finalSamples: [], speechSegments: [])
    let callsAfter = await fake.callCount
    #expect(callsAfter == callsBefore + 1, "short voiced tail IS decoded")
    #expect(r.accepted)
    #expect(r.text == "one two yes", "short final word appended, not dropped")
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

  // MARK: In-flight decode serialization (Codex r5 P2)

  /// Tracks concurrent `transcribe` calls and blocks the FIRST (loop) decode
  /// until released, so a test can prove the flush never starts a second decode
  /// while the loop decode is still in flight (WhisperKit decode is not
  /// cancellable mid-run — two concurrent transcribes on one model corrupt state).
  private actor GateDecoder: WhisperKitTranscribing {
    nonisolated func encodeText(_ text: String) -> [Int] { [] }
    private(set) var active = 0
    private(set) var maxActive = 0
    private(set) var loopEntered = false
    private var released = false
    private var callCount = 0
    private let loopResult: [TranscriptionResult]
    private let flushResult: [TranscriptionResult]

    init(loopResult: [TranscriptionResult], flushResult: [TranscriptionResult]) {
      self.loopResult = loopResult
      self.flushResult = flushResult
    }

    func release() { released = true }

    func transcribe(audioArray: [Float], decodeOptions: DecodingOptions?) async throws
      -> [TranscriptionResult]
    {
      let idx = callCount
      callCount += 1
      active += 1
      maxActive = max(maxActive, active)
      defer { active -= 1 }
      if idx == 0 {
        loopEntered = true
        while !released { await Task.yield() }  // block the loop decode until released
        return loopResult
      }
      return flushResult  // the flush tail decode
    }
  }

  @Test(
    "finalize serializes the flush behind an in-flight loop decode (never two concurrent transcribes)"
  )
  func flushSerializesWithLoopDecode() async throws {
    let loop = result(
      "one two three four",
      [seg(0, 1, "one"), seg(1, 2, "two"), seg(2, 3, "three"), seg(3, 5, "four")])
    let flush = result("before I send it", [seg(2, 5, "before I send it")])
    let dec = GateDecoder(loopResult: [loop], flushResult: [flush])
    let s = WhisperKitStreamingSession(
      whisperKit: dec, decodingOptions: DecodingOptions(),
      requiredSegmentsForConfirmation: 2, cadence: .milliseconds(1))
    let pcm = [Float](repeating: 0.4, count: 96_000)  // 6s, tail above the gate
    await s.start(audioSamplesProvider: fixedProvider(pcm))
    // Wait until the loop decode has entered and is blocked.
    while !(await dec.loopEntered) { await Task.yield() }
    // Finalize now: it must await the in-flight loop decode before flushing.
    async let outcome = s.finalize(finalSamples: [], speechSegments: [])
    await dec.release()  // let the loop decode return; finalize then flushes
    let r = await outcome
    let maxActive = await dec.maxActive
    #expect(maxActive == 1, "flush must not overlap the in-flight loop decode")
    #expect(r.accepted)
    #expect(r.text?.contains("before I send it") == true, "flush tail appended after serialization")
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

  // MARK: LocalAgreement-2 (#1276 PR-2 — UFAL HypothesisBuffer.flush port)

  /// Provider whose sample count grows by one decode-gate quantum per pull, so a
  /// test can drive MULTIPLE loop decodes (the fixed provider only ever allows
  /// one: no new audio after the first).
  private actor GrowingProvider {
    private var count: Int
    private let step: Int
    private let cap: Int
    init(start: Int, step: Int = 16_000, cap: Int) {
      self.count = start
      self.step = step
      self.cap = cap
    }
    func pull() -> (samples: [Float], count: Int) {
      let c = count
      count = min(cap, count + step)
      return ([Float](repeating: 0.3, count: c), c)
    }
  }

  private func word(_ start: Float, _ end: Float, _ text: String) -> WordTiming {
    WordTiming(word: text, tokens: [], start: start, end: end, probability: 1.0)
  }

  private func laSession(
    _ scripted: [[TranscriptionResult]]
  ) -> (WhisperKitStreamingSession, FakeDecoder) {
    let fake = FakeDecoder(scripted: scripted)
    let s = WhisperKitStreamingSession(
      whisperKit: fake, decodingOptions: DecodingOptions(),
      requiredSegmentsForConfirmation: 2, cadence: .milliseconds(1),
      localAgreement: true)
    return (s, fake)
  }

  @Test("LocalAgreement-2 commits the longest common word prefix of consecutive hypotheses")
  func localAgreementCommitsAgreedPrefix() async throws {
    // Decode 1: no previous hypothesis → nothing commits, all words held back.
    // Decode 2 agrees on all 3 previous words → they commit; "well" is held.
    let d1 = result(
      "the meeting went",
      [
        seg(0, 3, "the meeting went").with(words: [
          word(0, 1, "the"), word(1, 2, "meeting"), word(2, 3, "went"),
        ])
      ])
    let d2 = result(
      "the meeting went well",
      [
        seg(0, 4, "the meeting went well").with(words: [
          word(0, 1, "the"), word(1, 2, "meeting"), word(2, 3, "went"), word(3, 4, "well"),
        ])
      ])
    let (s, _) = laSession([[d1], [d2]])
    let provider = GrowingProvider(start: 80_000, cap: 112_000)
    await s.start(audioSamplesProvider: { await provider.pull() })
    await waitForDecode(2, s)
    #expect(await s.confirmedTextForTests == "the meeting went", "agreed prefix committed")
    #expect(await s.lastConfirmedSecForTests == 3.0, "advanced to last committed word end")
    await s.cancel()
  }

  @Test("LocalAgreement-2 holds back words past the first disagreement")
  func localAgreementStopsAtDisagreement() async throws {
    // Decode 2 disagrees at word 3 ("went" vs "want") → only the first 2 commit.
    let d1 = result(
      "the meeting went",
      [
        seg(0, 3, "the meeting went").with(words: [
          word(0, 1, "the"), word(1, 2, "meeting"), word(2, 3, "went"),
        ])
      ])
    let d2 = result(
      "the meeting want well",
      [
        seg(0, 4, "the meeting want well").with(words: [
          word(0, 1, "the"), word(1, 2, "meeting"), word(2, 3, "want"), word(3, 4, "well"),
        ])
      ])
    let (s, _) = laSession([[d1], [d2]])
    let provider = GrowingProvider(start: 80_000, cap: 112_000)
    await s.start(audioSamplesProvider: { await provider.pull() })
    await waitForDecode(2, s)
    #expect(await s.confirmedTextForTests == "the meeting", "commit stops at disagreement")
    #expect(await s.lastConfirmedSecForTests == 2.0)
    await s.cancel()
  }

  @Test("LocalAgreement holds a wordless decode: no confirmation, no duplicated prefix")
  func localAgreementHoldsWordlessDecode() async throws {
    // LA-mode decodes begin at bufferStartSec, so segment-lag confirmation on a
    // wordless decode would re-confirm already-committed audio and duplicate
    // the transcript (Codex r1 P2). A wordless cycle must change NOTHING.
    let segs = [seg(0, 1, "one"), seg(1, 2, "two"), seg(2, 3, "three"), seg(3, 4, "four")]
    let (s, _) = laSession([[result("one two three four", segs)]])
    let pcm = [Float](repeating: 0.3, count: 64_000)
    await s.start(audioSamplesProvider: fixedProvider(pcm))
    await waitForDecode(1, s)
    #expect(await s.confirmedTextForTests == "", "wordless decode held, nothing confirmed")
    #expect(await s.lastConfirmedSecForTests == 0.0)
    await s.cancel()
  }

  // MARK: LocalAgreement finalize (release fast path vs bounded buffer decode)

  /// Two-phase provider: the loop decode sees `loopCount` samples; after
  /// `advance()`, finalize's pull sees `finalCount` (fresh audio at stop).
  private actor TwoPhaseProvider {
    private let loopCount: Int
    private let finalCount: Int
    private var advanced = false
    init(loopCount: Int, finalCount: Int) {
      self.loopCount = loopCount
      self.finalCount = finalCount
    }
    func advance() { advanced = true }
    func pull() -> (samples: [Float], count: Int) {
      let n = advanced ? finalCount : loopCount
      return ([Float](repeating: 0.3, count: n), n)
    }
  }

  /// LA session for finalize tests. The fresh audio in these tests is kept
  /// UNDER the loop's 16k-sample decode gate (so a loop cycle can never race
  /// finalize for the next scripted result) but OVER finalize's 100ms voiced
  /// gate — the finalize path under test is deterministically the only
  /// consumer of scripted[1].
  private func laFinalizeSession(
    _ scripted: [[TranscriptionResult]]
  ) -> (WhisperKitStreamingSession, FakeDecoder) {
    let fake = FakeDecoder(scripted: scripted)
    let s = WhisperKitStreamingSession(
      whisperKit: fake, decodingOptions: DecodingOptions(),
      requiredSegmentsForConfirmation: 2, cadence: .milliseconds(1),
      localAgreement: true)
    return (s, fake)
  }

  @Test("LA finalize releases instantly (no decode) when the stream is caught up")
  func laFinalizeCaughtUpReleases() async throws {
    // One decode heard ALL the audio; nothing commits (no previous hypothesis)
    // so both words are the retained hypothesis. Finalize must release
    // confirmed+retained with ZERO further inference.
    let d1 = result(
      "the meeting",
      [
        seg(0, 2, "the meeting").with(words: [
          word(0, 1, "the"), word(1, 2, "meeting"),
        ])
      ])
    let (s, fake) = laFinalizeSession([[d1]])
    let pcm = [Float](repeating: 0.3, count: 48_000)
    await s.start(audioSamplesProvider: fixedProvider(pcm))
    await waitForDecode(1, s)
    let r = await s.finalize(finalSamples: [], speechSegments: [])
    #expect(r.accepted)
    #expect(r.text == "the meeting", "released the retained hypothesis")
    #expect(r.tailDecodeMs == 0, "no decode at stop")
    #expect(await fake.callCount == 1, "finalize ran zero inference")
    #expect(r.strategy == "streaming")
  }

  @Test("LA finalize runs ONE bounded buffer decode when fresh speech arrived at stop")
  func laFinalizeFreshSpeechDecodesBuffer() async throws {
    let d1 = result(
      "the meeting",
      [
        seg(0, 2, "the meeting").with(words: [
          word(0, 1, "the"), word(1, 2, "meeting"),
        ])
      ])
    let dFinal = result(
      "the meeting went well",
      [seg(0, 4, "the meeting went well")])
    let (s, fake) = laFinalizeSession([[d1], [dFinal]])
    let provider = TwoPhaseProvider(loopCount: 48_000, finalCount: 56_000)
    await s.start(audioSamplesProvider: { await provider.pull() })
    await waitForDecode(1, s)
    await provider.advance()  // 0.5s fresh voiced audio: below the loop gate, above the finalize gate
    let r = await s.finalize(finalSamples: [], speechSegments: [])
    #expect(r.accepted)
    #expect(r.text == "the meeting went well", "buffer decode output IS the transcript")
    #expect(await fake.callCount == 2, "exactly one finalize decode")
  }

  @Test("LA finalize forces batch fallback when the buffer decode returns empty")
  func laFinalizeEmptyBufferDecodeForcesFallback() async throws {
    let d1 = result(
      "the meeting",
      [
        seg(0, 2, "the meeting").with(words: [
          word(0, 1, "the"), word(1, 2, "meeting"),
        ])
      ])
    let dFinal = result("", [])
    let (s, _) = laFinalizeSession([[d1], [dFinal]])
    let provider = TwoPhaseProvider(loopCount: 48_000, finalCount: 56_000)
    await s.start(audioSamplesProvider: { await provider.pull() })
    await waitForDecode(1, s)
    await provider.advance()
    let r = await s.finalize(finalSamples: [], speechSegments: [])
    #expect(!r.accepted, "voiced fresh audio decoding empty must not ship truncated")
    #expect(r.strategy == "streaming_buffer_empty_fallback")
  }

  // MARK: Bounded conditioning prompt (UFAL prompt() 200-char suffix)

  @Test("promptSuffix returns short text whole and bounds long text at a word boundary")
  func promptSuffixBounds() {
    #expect(WhisperKitStreamingSession.promptSuffix(of: "short text") == "short text")
    let longText = (1...100).map { "word\($0)" }.joined(separator: " ")  // ~690 chars
    let suffix = WhisperKitStreamingSession.promptSuffix(of: longText)
    #expect(suffix.count <= 200, "bounded to the budget")
    #expect(longText.hasSuffix(suffix), "a true suffix of the source")
    let firstWord = suffix.split(separator: " ").first.map(String.init) ?? ""
    #expect(longText.contains(" " + firstWord + " "), "starts at a word boundary, no partial word")
    // Degenerate: one unbroken 300-char token — no space to trim at; must not crash.
    let unbroken = String(repeating: "a", count: 300)
    #expect(WhisperKitStreamingSession.promptSuffix(of: unbroken).count <= 200)
  }

  // MARK: Helpers

  private func waitForDecode(_ n: Int, _ s: WhisperKitStreamingSession) async {
    while await s.currentDecodeCount < n { await Task.yield() }
  }
}

/// Test sugar: attach word timings to a segment without repeating the full init.
extension TranscriptionSegment {
  fileprivate func with(words: [WordTiming]) -> TranscriptionSegment {
    var copy = self
    copy.words = words
    return copy
  }
}
