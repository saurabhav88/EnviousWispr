import EnviousWisprModelDelivery
import Testing

@testable import EnviousWisprAppKit

/// When the missing Finished calls model may download by itself (#4936). When this fails, a Mac
/// that updated never gets it, or 199 MB download on a first install, after Cancel or Remove, or
/// against the kill switch.
@Suite("SpeakerFinalFetchPolicy (#4936)", .tags(.productOutcome))
struct SpeakerFinalFetchPolicyTests {
  @Test("only a missing or failed model, with every gate open, starts")
  func table() {
    let open = SpeakerFinalFetchPolicy.Inputs(
      inThisBuild: true, meetingSetUp: true, liveState: .admitted, killSwitchOn: true,
      declined: false, requestBusy: false, finalState: .notReady)
    func expect(
      _ decision: SpeakerFinalFetchPolicy.Decision,
      sourceLocation: SourceLocation = #_sourceLocation,
      _ change: (inout SpeakerFinalFetchPolicy.Inputs) -> Void
    ) {
      var inputs = open
      change(&inputs)
      #expect(SpeakerFinalFetchPolicy.decide(inputs) == decision, sourceLocation: sourceLocation)
    }
    expect(.start) { _ in }
    expect(.start) { $0.finalState = .failed(DeliveryFailure(reason: .sourceUnreachable)) }
    expect(.hold(.notInThisBuild)) { $0.inThisBuild = false }
    expect(.hold(.setupIncomplete)) { $0.meetingSetUp = false }
    expect(.hold(.liveNotReady)) { $0.liveState = .verifying }
    expect(.hold(.killSwitchOff)) { $0.killSwitchOn = false }
    expect(.hold(.declined)) { $0.declined = true }
    expect(.hold(.inFlight)) { $0.requestBusy = true }
    expect(.hold(.alreadyAdmitted)) { $0.finalState = .admitted }
    expect(.hold(.inFlight)) { $0.finalState = .verifying }
    expect(.hold(.declined)) { $0.finalState = .cancelled(resumable: true) }
  }
}
