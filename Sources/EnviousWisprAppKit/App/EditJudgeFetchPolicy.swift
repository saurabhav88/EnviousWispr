import EnviousWisprModelDelivery
import EnviousWisprPostProcessing
import Foundation

// MARK: - When the correction judge downloads (#996 phase D)
//
// The delivery layer owns HOW bytes move; this value owns WHEN a download may
// start, and it is pure so every gate is a table test. Five gates, all
// required (grounded review Q3b, founder decisions 2026-09-20/21):
//
// 1. This build QUALIFIES the classifier somewhere: the bundled manifest can
//    ship ahead of its exam receipt, and an unqualified package must never
//    cost a user 323 MB.
// 2. Onboarding is complete: first-run setup owns the bandwidth ("download
//    alongside Parakeet" means after it, never instead of it).
// 3. Parakeet is admitted: the heart's model lands first.
// 4. No Debug UAT door: a launch that overrides the judge from an export must
//    not also fetch the shipped one behind the tester's back.
// 5. The `edit_judge` family kill switch is on (D5).
//
// And the judge is not already admitted, downloading, verifying or preparing:
// the controller single-flights per identity, but starting a fetch that is
// already running is still a wasted call, and starting one over an admitted
// model is a verification pass the user did not ask for.
//
// Metered or constrained networks are NOT a gate: the delivery stack allows
// constrained access for every family (Parakeet included), and a different
// policy for this model is a founder decision with its own contract amendment.
struct EditJudgeFetchPolicy: Equatable, Sendable {
  struct Inputs: Equatable, Sendable {
    var classifierQualifiedSomewhere: Bool
    var onboardingComplete: Bool
    var parakeetAdmitted: Bool
    var debugDoorPresent: Bool
    var killSwitchOn: Bool
    var judgeState: DeliveryState
    /// A Download press (or Remove and download again): a user's own cancel is
    /// no longer a reason to hold. Automatic triggers pass false.
    var userInitiated: Bool = false
  }

  enum Decision: Equatable, Sendable {
    case start
    case hold(Reason)

    enum Reason: String, Equatable, Sendable, CaseIterable {
      case notQualified
      case onboardingIncomplete
      case parakeetNotAdmitted
      case debugDoorPresent
      case killSwitchOff
      case alreadyAdmitted
      case inFlight
      /// The user cancelled this launch's download; the row offers Download
      /// and the policy never restarts it behind their back. A relaunch is a
      /// fresh `.notReady` and starts again.
      case cancelledByUser
    }
  }

  static func decide(_ inputs: Inputs) -> Decision {
    guard inputs.classifierQualifiedSomewhere else { return .hold(.notQualified) }
    guard inputs.onboardingComplete else { return .hold(.onboardingIncomplete) }
    guard inputs.parakeetAdmitted else { return .hold(.parakeetNotAdmitted) }
    guard !inputs.debugDoorPresent else { return .hold(.debugDoorPresent) }
    guard inputs.killSwitchOn else { return .hold(.killSwitchOff) }
    switch inputs.judgeState {
    case .admitted: return .hold(.alreadyAdmitted)
    case .preparing, .downloading, .verifying: return .hold(.inFlight)
    case .cancelled: return inputs.userInitiated ? .start : .hold(.cancelledByUser)
    // A failed attempt retries on the NEXT trigger (launch, onboarding
    // completion, Parakeet admission), never in a loop: the triggers are
    // discrete events, so a dead mirror costs one attempt per event.
    case .notReady, .failed: return .start
    }
  }
}
