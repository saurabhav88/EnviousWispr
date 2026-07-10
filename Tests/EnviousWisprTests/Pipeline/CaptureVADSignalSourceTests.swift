import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPipeline

// MARK: - CaptureVADSignalSourceTests (epic #827, PR-4 §11.4)
//
// Unit coverage for `CaptureVADSignalSource` — signal bridging, the
// `speechEvidenceAtStop()` tri-state, and `SessionID` stamping.

@MainActor
@Suite struct CaptureVADSignalSourceTests {

  @Test("noteAutoStopTriggered yields an autoStop signal stamped with the current session")
  func autoStopBridging() async {
    let source = CaptureVADSignalSource()
    let sid = SessionID()
    source.setCurrentSessionID(sid)
    var iterator = source.subscribeStopSignals().makeAsyncIterator()
    source.noteAutoStopTriggered()
    let signal = await iterator.next()
    #expect(signal == VADStopSignal(kind: .autoStopTriggered, sessionID: sid))
  }

  @Test("noteMaxDurationReached yields a maxDuration signal")
  func maxDurationBridging() async {
    let source = CaptureVADSignalSource()
    let sid = SessionID()
    source.setCurrentSessionID(sid)
    var iterator = source.subscribeStopSignals().makeAsyncIterator()
    source.noteMaxDurationReached()
    let signal = await iterator.next()
    #expect(signal == VADStopSignal(kind: .maxDurationReached, sessionID: sid))
  }

  @Test("noteApproachingMaxDuration yields a warning signal stamped with the current session")
  func warningBridging() async {
    let source = CaptureVADSignalSource()
    let sid = SessionID()
    source.setCurrentSessionID(sid)
    var iterator = source.subscribeWarningSignals().makeAsyncIterator()
    source.noteApproachingMaxDuration(remainingSeconds: 60)
    let signal = await iterator.next()
    #expect(signal == VADWarningSignal(remainingSeconds: 60, sessionID: sid))
  }

  @Test("a warning never appears on the stop stream (#1060 separate streams)")
  func warningDoesNotRideStopStream() async {
    let source = CaptureVADSignalSource()
    source.setCurrentSessionID(SessionID())
    var stopIterator = source.subscribeStopSignals().makeAsyncIterator()
    source.noteApproachingMaxDuration(remainingSeconds: 60)  // must NOT reach the stop stream
    source.noteMaxDurationReached()
    let signal = await stopIterator.next()
    #expect(signal?.kind == .maxDurationReached)
  }

  @Test("bind claims onVADAutoStop — the XPC callback drives a stop signal")
  func bindOwnsXPCCallback() async {
    let source = CaptureVADSignalSource()
    let capture = FakeAudioCapture()
    let sid = SessionID()
    source.setCurrentSessionID(sid)
    source.bind(audioCapture: capture)
    var iterator = source.subscribeStopSignals().makeAsyncIterator()
    capture.fireVADAutoStop()  // the XPC service-side detector fires
    let signal = await iterator.next()
    #expect(signal == VADStopSignal(kind: .autoStopTriggered, sessionID: sid))
  }

  /// #1408 A3: `bind` claims BOTH callback slots. The manager's hard-cap
  /// backstop funnels into the SAME typed, session-stamped stop route the
  /// graceful wall-clock cap uses — a normal `.maxDuration` stop, never an
  /// engine interruption.
  @Test("bind claims onMaxDurationReached — the backstop drives a typed stop signal")
  func bindOwnsMaxDurationCallback() async {
    let source = CaptureVADSignalSource()
    let capture = FakeAudioCapture()
    let sid = SessionID()
    source.setCurrentSessionID(sid)
    source.bind(audioCapture: capture)
    var iterator = source.subscribeStopSignals().makeAsyncIterator()
    capture.fireMaxDurationReached()  // the manager backstop fires
    let signal = await iterator.next()
    #expect(signal == VADStopSignal(kind: .maxDurationReached, sessionID: sid))
  }

  @Test("each signal carries the session current at emit time")
  func sessionStamping() async {
    let source = CaptureVADSignalSource()
    let first = SessionID()
    let second = SessionID()
    var iterator = source.subscribeStopSignals().makeAsyncIterator()

    source.setCurrentSessionID(first)
    source.noteAutoStopTriggered()
    source.setCurrentSessionID(second)
    source.noteAutoStopTriggered()

    let a = await iterator.next()
    let b = await iterator.next()
    #expect(a?.sessionID == first)
    #expect(b?.sessionID == second, "a re-stamped session is reflected in later signals")
  }

  // MARK: PR-5 Rung 5 Codex code-diff r1 P1 — per-subscriber broadcast
  //
  // The source is shared between two `KernelDictationDriver`s in production
  // (Parakeet + WhisperKit) via `WisprBootstrapper.swift:148`. A single
  // `AsyncStream` delivers each yield to exactly one iterator, so an
  // overlap between the two kernels' `subscribeVADSignals` tasks could
  // swallow a stop signal before the active driver saw it. Each
  // `subscribeStopSignals()` call must vend a fresh stream, and every
  // emit must reach every live subscriber.

  @Test("subscribeStopSignals — every live subscriber receives every signal")
  func broadcastDeliversToAllSubscribers() async {
    let source = CaptureVADSignalSource()
    let sid = SessionID()
    source.setCurrentSessionID(sid)

    var iterA = source.subscribeStopSignals().makeAsyncIterator()
    var iterB = source.subscribeStopSignals().makeAsyncIterator()

    source.noteAutoStopTriggered()
    let a = await iterA.next()
    let b = await iterB.next()

    #expect(a == VADStopSignal(kind: .autoStopTriggered, sessionID: sid))
    #expect(b == VADStopSignal(kind: .autoStopTriggered, sessionID: sid))
  }

  @Test("subscribeStopSignals — second subscriber added mid-stream sees only later signals")
  func lateSubscriberSeesLaterSignalsOnly() async {
    let source = CaptureVADSignalSource()
    let sid = SessionID()
    source.setCurrentSessionID(sid)

    var iterA = source.subscribeStopSignals().makeAsyncIterator()
    source.noteAutoStopTriggered()  // delivered to A only — B is not subscribed yet
    let a1 = await iterA.next()
    #expect(a1?.kind == .autoStopTriggered)

    var iterB = source.subscribeStopSignals().makeAsyncIterator()
    source.noteMaxDurationReached()  // delivered to A AND B
    let a2 = await iterA.next()
    let b1 = await iterB.next()
    #expect(a2?.kind == .maxDurationReached)
    #expect(b1?.kind == .maxDurationReached)
  }

  @Test("speechEvidenceAtStop returns the configured tri-state")
  func evidenceTriState() {
    let source = CaptureVADSignalSource()
    // Default — no detector ran.
    #expect(source.speechEvidenceAtStop() == .unavailable)

    source.setEvidenceProvider { .voiced }
    #expect(source.speechEvidenceAtStop() == .voiced)

    source.setEvidenceProvider { .confirmedNoSpeech }
    #expect(source.speechEvidenceAtStop() == .confirmedNoSpeech)
  }
}
