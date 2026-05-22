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
    var iterator = source.stopSignals.makeAsyncIterator()
    source.noteAutoStopTriggered()
    let signal = await iterator.next()
    #expect(signal == VADStopSignal(kind: .autoStopTriggered, sessionID: sid))
  }

  @Test("noteMaxDurationReached yields a maxDuration signal")
  func maxDurationBridging() async {
    let source = CaptureVADSignalSource()
    let sid = SessionID()
    source.setCurrentSessionID(sid)
    var iterator = source.stopSignals.makeAsyncIterator()
    source.noteMaxDurationReached()
    let signal = await iterator.next()
    #expect(signal == VADStopSignal(kind: .maxDurationReached, sessionID: sid))
  }

  @Test("bind claims onVADAutoStop — the XPC callback drives a stop signal")
  func bindOwnsXPCCallback() async {
    let source = CaptureVADSignalSource()
    let capture = FakeAudioCapture()
    let sid = SessionID()
    source.setCurrentSessionID(sid)
    source.bind(audioCapture: capture)
    var iterator = source.stopSignals.makeAsyncIterator()
    capture.fireVADAutoStop()  // the XPC service-side detector fires
    let signal = await iterator.next()
    #expect(signal == VADStopSignal(kind: .autoStopTriggered, sessionID: sid))
  }

  @Test("each signal carries the session current at emit time")
  func sessionStamping() async {
    let source = CaptureVADSignalSource()
    let first = SessionID()
    let second = SessionID()
    var iterator = source.stopSignals.makeAsyncIterator()

    source.setCurrentSessionID(first)
    source.noteAutoStopTriggered()
    source.setCurrentSessionID(second)
    source.noteAutoStopTriggered()

    let a = await iterator.next()
    let b = await iterator.next()
    #expect(a?.sessionID == first)
    #expect(b?.sessionID == second, "a re-stamped session is reflected in later signals")
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
