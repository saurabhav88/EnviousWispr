import Foundation
import Testing

@testable import EnviousWisprPipeline

/// `FakeVADSignalSource` behavior tests (epic #827, PR-2 plan §11.2 item F).
@MainActor
@Suite("FakeVADSignalSource")
struct FakeVADSignalSourceTests {

  @Test("emits each stop-signal kind, stamped with the current session")
  func emitsStopSignals() async {
    let vad = FakeVADSignalSource()
    let session = SessionID()
    vad.currentSessionID = session
    let collected = CollectedSignals()
    let consumer = Task { @MainActor in
      for await signal in vad.subscribeStopSignals() { collected.value.append(signal) }
    }
    await Task.yield()
    vad.emit(.autoStopTriggered)
    vad.emit(.maxDurationReached)
    vad.finish()
    await consumer.value
    #expect(collected.value.map(\.kind) == [.autoStopTriggered, .maxDurationReached])
    #expect(
      collected.value.allSatisfy { $0.sessionID == session },
      "every signal carries the current SessionID — the stale-callback gate")
    #expect(vad.emittedKinds == [.autoStopTriggered, .maxDurationReached])
  }

  @Test("speechEvidenceAtStop returns the configured tri-state verdict")
  func speechEvidenceTriState() {
    let vad = FakeVADSignalSource()
    #expect(vad.speechEvidenceAtStop() == .voiced, "defaults to .voiced")
    vad.evidence = .confirmedNoSpeech
    #expect(vad.speechEvidenceAtStop() == .confirmedNoSpeech)
    vad.evidence = .unavailable
    #expect(vad.speechEvidenceAtStop() == .unavailable)
    #expect(vad.evidenceReadCount == 3)
  }

  @MainActor
  final class CollectedSignals {
    var value: [VADStopSignal] = []
  }
}
