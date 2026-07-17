@preconcurrency import AVFoundation
import EnviousWisprASR
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPipeline

// MARK: - LIDPerfSignpostSessionIDTests (epic #827, PR-5 Rung 4.5)
//
// Coverage for the LID perf signpost `session_id` plumbing restored in this
// rung. The OLD `KernelDictationDriver` emitted `session_id` on every signpost
// line via `audioCapture.currentCaptureSessionID`
// (`KernelDictationDriver.swift:1438-1452`). The new adapter dropped the
// parameter — this rung restores it, and CAPTURES the value once per session
// at `beginSession` rather than resolving via a late closure (Codex grounded
// review r1 finding: direct sources increment generation on every
// `startCapture`, so a delayed `t_clipboard_write` reading live would see
// session B while emitting session A telemetry).
//
// What these tests assert:
// 1. Adapter init takes an `audioCaptureSessionIDSource` closure and reads
//    it ONCE, at finalize entry (NOT at `beginSession` -- the closure is
//    read zero times right after `beginSession` and exactly once by the
//    time `finalize` returns; #1626 corrected this stale claim).
// 2. `KernelASRAdapterDiagnostics.lidCaptureSessionID` carries the captured
//    value through to wiring after finalize.
// 3. The same diagnostics carry voiced duration, LID window count, and clip
//    kind so the kernel-side and wiring-side emitters can format their
//    signpost lines.

@MainActor
@Suite struct LIDPerfSignpostSessionIDTests {

  // MARK: Capture at finalize entry (NOT beginSession)

  @Test("adapter does NOT read audioCaptureSessionIDSource at beginSession")
  func adapterDoesNotCaptureAtBeginSession() async throws {
    var readCount = 0
    let adapter = WhisperKitEngineAdapter(
      backend: StubWhisperKitBackend(),
      audioCaptureSessionIDSource: {
        readCount += 1
        return 42
      })

    try await adapter.beginSession(SessionID(), options: .default, streaming: false)
    // Kernel calls beginSession BEFORE beginCapturePhase mints a new id, so
    // reading the source here would capture a stale value. The adapter must
    // defer the read until finalize entry.
    #expect(readCount == 0, "no read at beginSession; capture deferred to finalize")
  }

  @Test("adapter reads audioCaptureSessionIDSource at finalize entry")
  func adapterCapturesSessionIDAtFinalizeEntry() async throws {
    let backend = StubWhisperKitBackend()
    await backend.setTranscribeResult(
      ASRResult(
        text: "ok", language: "en", duration: 1.0,
        processingTime: 0.1, backendType: .whisperKit))
    var readCount = 0
    let adapter = WhisperKitEngineAdapter(
      backend: backend,
      audioCaptureSessionIDSource: {
        readCount += 1
        return 555
      })

    try await adapter.beginSession(
      SessionID(),
      options: TranscriptionOptions(language: "en"),  // locked
      streaming: false)
    // Feed a buffer so finalize has audio to process.
    let buf = AVAudioPCMBuffer(
      pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!,
      frameCapacity: 16000)!
    buf.frameLength = 16000
    adapter.acceptAudio(
      AudioBufferHandoff(buffer: buf, frameCount: 16000, sequence: 1, sessionID: SessionID()))

    _ = await adapter.finalize(batchSamples: nil)
    #expect(readCount == 1, "finalize reads the source exactly once")

    let diag = try #require(adapter.lastASRDiagnostics)
    #expect(diag.lidCaptureSessionID == 555)
  }

  // MARK: Diagnostics transport

  @Test("finalize populates lidCaptureSessionID on diagnostics for wiring transport")
  func finalizePopulatesLIDDiagnosticsForWiring() async throws {
    let backend = StubWhisperKitBackend()
    await backend.setTranscribeResult(
      ASRResult(
        text: "hola mundo", language: "es", duration: 1.0,
        processingTime: 0.1, backendType: .whisperKit))

    let capturedID: UInt64 = 7777
    let adapter = WhisperKitEngineAdapter(
      backend: backend,
      audioCaptureSessionIDSource: { capturedID })

    try await adapter.beginSession(
      SessionID(),
      options: TranscriptionOptions(language: nil),  // .auto so LID runs
      streaming: false)

    // Feed a non-trivial PCM so the finalize path runs LID + decode.
    let samples = [Float](repeating: 0.1, count: 32000)  // 2s @ 16kHz
    let buf = AVAudioPCMBuffer(
      pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!,
      frameCapacity: AVAudioFrameCount(samples.count))!
    buf.frameLength = AVAudioFrameCount(samples.count)
    for i in 0..<samples.count {
      buf.floatChannelData![0][i] = samples[i]
    }
    adapter.acceptAudio(
      AudioBufferHandoff(
        buffer: buf,
        frameCount: samples.count,
        sequence: 1,
        sessionID: SessionID()))

    _ = await adapter.finalize(batchSamples: nil)

    let diag = try #require(adapter.lastASRDiagnostics)
    #expect(diag.lidCaptureSessionID == capturedID)
    // LID-shape transport fields populated alongside the captured id. This
    // test never calls `observeSpeechSegments`, so `speechSegments` is empty
    // and `voicedDurationSec` computes to 0.0 (not the fed sample count) --
    // 0.0 < the 3.0s single-window threshold still yields 1 window / "short"
    // (traced against the real adapter finalize path, #1626 grounded review).
    #expect(diag.lidVoicedDurationSec == 0.0)
    #expect(diag.lidWindowCount == 1)
    #expect(diag.lidClipKind == "short")
  }

  @Test("KernelASRAdapterDiagnostics defaults: LID fields all nil before finalize")
  func diagnosticsDefaultsLIDFieldsNil() {
    let diag = KernelASRAdapterDiagnostics()
    #expect(diag.lidCaptureSessionID == nil)
    #expect(diag.lidVoicedDurationSec == nil)
    #expect(diag.lidWindowCount == nil)
    #expect(diag.lidClipKind == nil)
  }
}
