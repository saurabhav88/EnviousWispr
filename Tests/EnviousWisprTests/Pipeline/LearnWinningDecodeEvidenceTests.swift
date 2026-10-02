@preconcurrency import AVFoundation
import EnviousWisprASR
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// #3338 PR-4 chunk 2: the learn hold may only ever keep the exact input of the
/// decode that produced the pasted text. When these fail, a later learn re-check
/// would listen to audio that is not what the user's text came from (or to
/// another take's audio), and could learn a word the user never said.
///
/// The independent record of "what the decoder actually received" is the stub
/// engine's own `lastTranscribeSamples`, written by the stub, not by the code under test.
@MainActor
@Suite("Learn evidence from the winning decode (#3338)", .tags(.productOutcome))
struct LearnWinningDecodeEvidenceTests {

  private let policy = LearnEvidencePolicy(maxSamples: 16_000 * 120)
  private let timings = [ASRWordTiming(word: "Kubernetes", range: 0..<10, startMs: 0, endMs: 400)]

  private func result(_ text: String, timings: [ASRWordTiming]? = nil) -> ASRResult {
    ASRResult(
      text: text, language: nil, duration: 1, processingTime: 0.1, backendType: .parakeet,
      wordTimings: timings,
      wordTimingCoverage: timings.map { _ in ASRWordTimingCoverage(timed: 10, total: 10) })
  }

  private func options(language: String?) -> TranscriptionOptions {
    var o = TranscriptionOptions.default
    o.language = language
    return o
  }

  private func feed(_ adapter: ParakeetEngineAdapter, samples: [Float], session: SessionID) throws {
    let buffer = try #require(FakeAudioCapture.makeBuffer(samples: samples))
    adapter.acceptAudio(
      AudioBufferHandoff(buffer: buffer, frameCount: samples.count, sequence: 1, sessionID: session)
    )
  }

  private func bits(_ x: [Float]) -> [UInt32] { x.map(\.bitPattern) }

  private func evidence(_ adapter: ParakeetEngineAdapter) -> LearnDecodeEvidence? {
    (adapter as ASREngineLearnAudioEvidenceProviding).lastLearnEvidence
  }

  @Test(
    "batch with the kernel's samples keeps exactly what the decoder received, its language and its timings"
  )
  func batchKernelInput() async throws {
    let manager = StubParakeetASRManager()
    manager.transcribeResult = result("Kubernetes now", timings: timings)
    let adapter = ParakeetEngineAdapter(asrManager: manager)
    try await adapter.beginSession(SessionID(), options: options(language: "de"), streaming: false)
    adapter.setLearnEvidencePolicy(policy)
    let input: [Float] = [0.5, -0.25, 0.125, Float.leastNonzeroMagnitude, -1]
    guard case .transcript = await adapter.finalize(batchSamples: input) else {
      Issue.record("expected a transcript")
      return
    }
    let e = try #require(evidence(adapter))
    #expect(bits(e.samples) == bits(manager.lastTranscribeSamples))
    #expect(bits(e.samples) == bits(input))
    #expect(e.attempt == .batch)
    #expect(e.callerSupplied)
    #expect(e.language == "de")
    #expect(e.rawText == "Kubernetes now")
    #expect(e.wordTimings == timings)
    let record = try #require(
      RecordingSessionKernel.learnTakeAudio(from: e, decode: .primary, takeID: "take-1"))
    #expect(record.decodePath == .conditionedBatch)
    #expect(record.sampleOrigin == .kernelASRInput)
    #expect(record.decodeLanguage == "de")
  }

  @Test("batch without kernel samples keeps the adapter's own retained PCM and says so")
  func batchAdapterFallback() async throws {
    let manager = StubParakeetASRManager()
    manager.transcribeResult = result("hello there")
    let adapter = ParakeetEngineAdapter(asrManager: manager)
    let sid = SessionID()
    try await adapter.beginSession(sid, options: options(language: nil), streaming: false)
    adapter.setLearnEvidencePolicy(policy)
    try feed(adapter, samples: [0.1, 0.2, 0.3], session: sid)
    guard case .transcript = await adapter.finalize(batchSamples: nil) else {
      Issue.record("expected a transcript")
      return
    }
    let e = try #require(evidence(adapter))
    #expect(!manager.lastTranscribeSamples.isEmpty)
    #expect(bits(e.samples) == bits(manager.lastTranscribeSamples))
    #expect(!e.callerSupplied)
    #expect(e.language == nil)
    let record = try #require(
      RecordingSessionKernel.learnTakeAudio(from: e, decode: .primary, takeID: "t"))
    #expect(record.decodePath == .batch)
    #expect(record.sampleOrigin == .adapterRetainedPCM)
  }

  @Test("a successful streaming finalize keeps nothing")
  func streamingSuccessKeepsNothing() async throws {
    let manager = StubParakeetASRManager()
    manager.finalizeStreamingResult = result("streamed text")
    let adapter = ParakeetEngineAdapter(asrManager: manager)
    let sid = SessionID()
    try await adapter.beginSession(sid, options: .default, streaming: true)
    adapter.setLearnEvidencePolicy(policy)
    try feed(adapter, samples: [0.1, 0.2], session: sid)
    guard case .transcript = await adapter.finalize(batchSamples: [0.1, 0.2]) else {
      Issue.record("expected a transcript")
      return
    }
    #expect(manager.transcribeCount == 0, "the streaming result won; no batch decode ran")
    #expect(evidence(adapter) == nil)
  }

  @Test("a streaming rescue keeps its own batch input, from the kernel or from retained PCM")
  func streamingRescue() async throws {
    for kernelSupplied in [true, false] {
      let manager = StubParakeetASRManager()
      manager.finalizeStreamingThrows = true
      manager.transcribeResult = result("rescued")
      let adapter = ParakeetEngineAdapter(asrManager: manager)
      let sid = SessionID()
      try await adapter.beginSession(sid, options: options(language: "fr"), streaming: true)
      adapter.setLearnEvidencePolicy(policy)
      try feed(adapter, samples: [0.4, 0.5, 0.6], session: sid)
      let input: [Float]? = kernelSupplied ? [0.9, -0.9, 0.3] : nil
      guard case .transcript = await adapter.finalize(batchSamples: input) else {
        Issue.record("expected a rescued transcript")
        continue
      }
      let e = try #require(evidence(adapter))
      #expect(bits(e.samples) == bits(manager.lastTranscribeSamples))
      #expect(e.attempt == .streamingRescue)
      #expect(e.callerSupplied == kernelSupplied)
      #expect(e.language == "fr")
      let record = try #require(
        RecordingSessionKernel.learnTakeAudio(from: e, decode: .primary, takeID: "t"))
      #expect(record.decodePath == .streamingRescueBatch)
      #expect(record.sampleOrigin == (kernelSupplied ? .kernelASRInput : .adapterRetainedPCM))
    }
  }

  @Test("a winning retry replaces the failed first decode's absence with its own input")
  func retryReplaces() async throws {
    let manager = StubParakeetASRManager()
    manager.transcribeThrows = true
    let adapter = ParakeetEngineAdapter(asrManager: manager)
    try await adapter.beginSession(SessionID(), options: options(language: "it"), streaming: false)
    adapter.setLearnEvidencePolicy(policy)
    guard case .failed = await adapter.finalize(batchSamples: [0.1, 0.2]) else {
      Issue.record("expected the first decode to fail")
      return
    }
    #expect(evidence(adapter) == nil, "a failed decode keeps nothing")
    manager.transcribeThrows = false
    manager.isModelLoaded = true
    manager.transcribeResult = result("retried")
    let retryInput: [Float] = [0.7, 0.8, -0.1]
    guard case .transcript = await adapter.retryDecode(inputSamples: retryInput) else {
      Issue.record("expected the retry to win")
      return
    }
    let e = try #require(evidence(adapter))
    #expect(bits(e.samples) == bits(retryInput))
    #expect(bits(e.samples) == bits(manager.lastTranscribeSamples))
    #expect(e.attempt == .retry)
    let record = try #require(
      RecordingSessionKernel.learnTakeAudio(from: e, decode: .retry, takeID: "t"))
    #expect(record.decodePath == .retry)
    #expect(record.sampleOrigin == .kernelASRInput)
    #expect(record.rawText == "retried")
  }

  @Test(
    "a salvage decode of a lead-trimmed slice is recorded as salvage, replacing the empty primary")
  func salvageSlice() async throws {
    let manager = StubParakeetASRManager()
    manager.transcribeResult = result("")
    let adapter = ParakeetEngineAdapter(asrManager: manager)
    try await adapter.beginSession(SessionID(), options: options(language: "es"), streaming: false)
    adapter.setLearnEvidencePolicy(policy)
    let full: [Float] = [0.0, 0.0, 0.0, 0.2, 0.3, 0.4]
    guard case .empty = await adapter.finalize(batchSamples: full) else {
      Issue.record("expected an empty primary decode")
      return
    }
    #expect(evidence(adapter) == nil, "an empty decode keeps nothing")
    manager.transcribeResult = result("salvaged")
    let slice = Array(full[3...])
    guard case .transcript = await adapter.finalize(batchSamples: slice) else {
      Issue.record("expected the salvage decode to win")
      return
    }
    let e = try #require(evidence(adapter))
    #expect(bits(e.samples) == bits(slice))
    #expect(bits(e.samples) == bits(manager.lastTranscribeSamples))
    let record = try #require(
      RecordingSessionKernel.learnTakeAudio(from: e, decode: .salvage, takeID: "t"))
    #expect(record.decodePath == .leadSalvage)
    #expect(record.sampleOrigin == .leadTrimmedASRInput)
    #expect(record.decodeLanguage == "es")
  }

  @Test("no policy, or a take over the cap, keeps nothing; the cap boundary itself is kept")
  func policyAndCap() async throws {
    for (pol, count, kept) in [
      (nil as LearnEvidencePolicy?, 4, false),
      (LearnEvidencePolicy(maxSamples: 4), 5, false),
      (LearnEvidencePolicy(maxSamples: 4), 4, true),
    ] {
      let manager = StubParakeetASRManager()
      manager.transcribeResult = result("text")
      let adapter = ParakeetEngineAdapter(asrManager: manager)
      try await adapter.beginSession(SessionID(), options: .default, streaming: false)
      adapter.setLearnEvidencePolicy(pol)
      let input = [Float](repeating: 0.1, count: count)
      guard case .transcript = await adapter.finalize(batchSamples: input) else {
        Issue.record("expected a transcript")
        continue
      }
      #expect(
        (evidence(adapter) != nil) == kept, "policy \(String(describing: pol)) count \(count)")
      if let e = evidence(adapter) { #expect(e.samples.count == count, "never truncated") }
    }
  }

  @Test("a new session clears the policy and the evidence; a stale decode commits nothing")
  func newSessionAndStale() async throws {
    let manager = StubParakeetASRManager()
    manager.transcribeResult = result("first")
    let adapter = ParakeetEngineAdapter(asrManager: manager)
    try await adapter.beginSession(SessionID(), options: .default, streaming: false)
    adapter.setLearnEvidencePolicy(policy)
    _ = await adapter.finalize(batchSamples: [0.1])
    #expect(evidence(adapter) != nil)
    try await adapter.beginSession(SessionID(), options: .default, streaming: false)
    #expect(evidence(adapter) == nil, "the next session starts with nothing")
    _ = await adapter.finalize(batchSamples: [0.2])
    #expect(evidence(adapter) == nil, "the next session has no policy until one is set")

    // Stale: session A's rescue decode commits after session B began.
    let m2 = StubParakeetASRManager()
    m2.slowFinalizeStreaming = true
    m2.finalizeStreamingThrows = true
    m2.transcribeResult = result("stale A")
    let a2 = ParakeetEngineAdapter(asrManager: m2)
    let sidA = SessionID()
    try await a2.beginSession(sidA, options: .default, streaming: true)
    a2.setLearnEvidencePolicy(policy)
    try feed(a2, samples: [0.3], session: sidA)
    async let outcomeA = a2.finalize(batchSamples: [0.3])
    await m2.waitForFinalizeStreamingCount(1)
    try await a2.beginSession(SessionID(), options: .default, streaming: false)
    a2.setLearnEvidencePolicy(policy)
    _ = await outcomeA
    #expect(
      evidence(a2) == nil, "a stale session's decode never becomes the new session's evidence")
  }

  @Test("cancel clears the evidence")
  func cancelClears() async throws {
    let manager = StubParakeetASRManager()
    manager.transcribeResult = result("text")
    let adapter = ParakeetEngineAdapter(asrManager: manager)
    try await adapter.beginSession(SessionID(), options: .default, streaming: false)
    adapter.setLearnEvidencePolicy(policy)
    _ = await adapter.finalize(batchSamples: [0.1])
    #expect(evidence(adapter) != nil)
    await adapter.cancel()
    #expect(evidence(adapter) == nil)
  }

  @Test("no record without a take id")
  func noTakeID() {
    let e = LearnDecodeEvidence(
      samples: [0.1], attempt: .batch, callerSupplied: true, language: nil, rawText: "a",
      wordTimings: nil)
    #expect(RecordingSessionKernel.learnTakeAudio(from: e, decode: .primary, takeID: nil) == nil)
  }
}
