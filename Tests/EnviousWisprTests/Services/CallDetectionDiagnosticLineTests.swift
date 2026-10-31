import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprServices

/// #4249: the call rules explain themselves in `app.log`, so a call whose end never started the
/// countdown can be diagnosed from the log alone.
@Suite("Call detection diagnostic line", .tags(.observabilityContract))
struct CallDetectionDiagnosticLineTests {
  typealias Policy = CallDetectionPolicy
  private let fixture = CallDetectionPolicyTests()

  @Test("a recorded call says it is recording with live evidence and no end reads yet")
  func recordingLine() {
    let s = fixture.recordingZoom()
    let line = s.policy.diagnosticLine(s.context)
    #expect(line.contains("meeting=recording"))
    #expect(line.contains("episode=1 app=zoom phase=recording"))
    #expect(line.contains("end_reads=0/\(Policy.endReadingsRequired)"))
    #expect(line.contains("interaction=none"))
  }

  @Test("a confirmed end shows the countdown, and a call that never reports an end shows why")
  func endLines() {
    var ended = fixture.recordingZoom()
    fixture.end(&ended)
    let endedLine = ended.policy.diagnosticLine(ended.context)
    #expect(endedLine.contains("phase=ending"))
    #expect(endedLine.contains("interaction=countdown"))
    #expect(endedLine.contains("evidence=ended"))

    // The window reads as unknown after the user leaves: no end is ever counted.
    var silent = fixture.recordingZoom()
    silent.observeCall(.unknown, holder: CallDetectionPolicyTests.zoom(.active))
    silent.read([CallDetectionPolicyTests.zoom(.inactive)])
    silent.wait(30)
    silent.read([CallDetectionPolicyTests.zoom(.inactive)])
    let silentLine = silent.policy.diagnosticLine(silent.context)
    #expect(silentLine.contains("phase=recording"))
    #expect(silentLine.contains("end_reads=0/\(Policy.endReadingsRequired)"))
    #expect(!silentLine.contains("interaction=countdown"))
    #expect(silentLine.contains("evidence=unknown"))
  }

  @Test(
    "a fresh ongoing view blocks the end, so the line says ongoing even when an ended view is newer"
  )
  func ongoingBlocksEndedInTheLine() {
    var s = fixture.recordingZoom()
    // Two sources of the same call: one still says ongoing, a later one says ended.
    let other = CallDetectionPolicyTests.zoom(.active, pid: 101)
    s.observeCall(
      .ongoing(family: .zoom, room: "w"), holder: CallDetectionPolicyTests.zoom(.active),
      owner: CallDetectionPolicyTests.Story.owner(for: CallDetectionPolicyTests.zoom(.active)))
    s.observeCall(
      .ended(family: .zoom, room: "w"), holder: other,
      owner: CallDetectionPolicyTests.Story.owner(for: CallDetectionPolicyTests.zoom(.active)))
    s.read([CallDetectionPolicyTests.zoom(.active), other])
    let line = s.policy.diagnosticLine(s.context)
    #expect(line.contains("observations=2"), "both views apply to the call: \(line)")
    #expect(line.contains("evidence=ongoing"), "an ongoing view blocks the end: \(line)")
    #expect(!line.contains("end_reads=1"), "no end read is counted: \(line)")
  }

  @Test("the line carries no room, process id or link, only states and counts")
  func lineHasNoContent() {
    var s = CallDetectionPolicyTests.Story()
    let holder = CallDetectionPolicyTests.zoom(
      .active, evidence: .call(family: .zoom, room: "secret-room-4249"), pid: 31337)
    s.ongoing(holder)
    s.press(.yes)
    s.startFinished(.recording(meetingID: UUID()))
    let line = s.policy.diagnosticLine(s.context)
    #expect(line.contains("phase=recording"), "the story reached a recording: \(line)")
    for forbidden in ["secret-room", "31337", "pid", "http"] {
      #expect(!line.contains(forbidden), "\(forbidden) must not appear: \(line)")
    }
  }
}
