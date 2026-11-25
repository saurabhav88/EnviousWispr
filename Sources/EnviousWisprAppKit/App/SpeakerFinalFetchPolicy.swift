import EnviousWisprModelDelivery

// MARK: - When the missing Finished calls model downloads by itself (#4936)
//
// Founder, 2026-11-25. Question: "May EnviousMeet download the missing voice model (199 MB) by
// itself after an update?" Answer: "Yes to auto update." (model-delivery contract §5d). The scope
// is this one model, on a Mac where EnviousMeet setup is done and the live half is ready: a user
// who set up before the second half existed would otherwise never get it.
//
// Pure, so every gate is a table test. A meeting is not a gate here: `ModelDeliveryHome` makes the
// decision only while no meeting is active. There is no network gate (founder 2026-07-29, #1419).
struct SpeakerFinalFetchPolicy: Equatable, Sendable {
  struct Inputs: Equatable, Sendable {
    /// The finished-calls model is in this build.
    var inThisBuild: Bool
    var meetingSetUp: Bool
    var liveState: DeliveryState
    var killSwitchOn: Bool
    /// The user's Cancel or Remove, kept until an accepted press.
    var declined: Bool
    /// A speaker labels request is queued or running, or a removal is running.
    var requestBusy: Bool
    var finalState: DeliveryState
  }

  enum Decision: Equatable, Sendable {
    case start
    case hold(Reason)

    enum Reason: String, Equatable, Sendable, CaseIterable {
      case notInThisBuild
      case setupIncomplete
      /// Never a first install: the live half is the user's own download.
      case liveNotReady
      case killSwitchOff
      case declined
      case inFlight
      case alreadyAdmitted
    }
  }

  static func decide(_ inputs: Inputs) -> Decision {
    guard inputs.inThisBuild else { return .hold(.notInThisBuild) }
    guard inputs.meetingSetUp else { return .hold(.setupIncomplete) }
    guard inputs.liveState == .admitted else { return .hold(.liveNotReady) }
    guard inputs.killSwitchOn else { return .hold(.killSwitchOff) }
    guard !inputs.declined else { return .hold(.declined) }
    guard !inputs.requestBusy else { return .hold(.inFlight) }
    switch inputs.finalState {
    case .admitted: return .hold(.alreadyAdmitted)
    case .preparing, .downloading, .verifying: return .hold(.inFlight)
    case .cancelled: return .hold(.declined)
    case .notReady, .failed: return .start
    }
  }
}
