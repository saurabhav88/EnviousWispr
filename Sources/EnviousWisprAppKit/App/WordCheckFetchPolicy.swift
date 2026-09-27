import EnviousWisprModelDelivery
import Foundation

// MARK: - When the word check downloads (#3242)
//
// The delivery layer owns HOW bytes move; this value owns WHEN a download may start, pure so
// every gate is a table test. Founder decisions 2026-09-26: the check is downloaded silently
// (about 440 MB) for anyone whose polish engine has no learned-word check of its own, and the
// only thing that turns it off is the Dictionary switch. Gates, all required:
//
// 1. The Dictionary switch is on ("Enable Dictionary", `wordCorrectionEnabled`).
// 2. Some chosen polish engine has no checker of its own: dictation's, or Transcribe a File's.
//    S1-mini and EG-1 users never pay for a model they would not use.
// 3. Onboarding is complete and Parakeet is admitted: the heart's model lands first, as for the
//    edit judge.
// 4. The `word_check` family kill switch is on.
//
// And the model is not already admitted or in flight, and a user's own cancel is respected until
// they ask again (Try again) or relaunch.
struct WordCheckFetchPolicy: Equatable, Sendable {
  struct Inputs: Equatable, Sendable {
    var dictionaryEnabled: Bool
    var someEngineLacksOwnChecker: Bool
    var onboardingComplete: Bool
    var parakeetAdmitted: Bool
    var killSwitchOn: Bool
    var state: DeliveryState
    /// "Try again" in the Dictionary row. Automatic triggers pass false.
    var userInitiated: Bool = false
  }

  enum Decision: Equatable, Sendable {
    case start
    case hold(Reason)

    enum Reason: String, Equatable, Sendable, CaseIterable {
      case dictionaryOff
      case notNeeded
      case onboardingIncomplete
      case parakeetNotAdmitted
      case killSwitchOff
      case alreadyAdmitted
      case inFlight
      case cancelledByUser
    }
  }

  static func decide(_ inputs: Inputs) -> Decision {
    guard inputs.dictionaryEnabled else { return .hold(.dictionaryOff) }
    guard inputs.someEngineLacksOwnChecker else { return .hold(.notNeeded) }
    guard inputs.onboardingComplete else { return .hold(.onboardingIncomplete) }
    guard inputs.parakeetAdmitted else { return .hold(.parakeetNotAdmitted) }
    guard inputs.killSwitchOn else { return .hold(.killSwitchOff) }
    switch inputs.state {
    case .admitted: return .hold(.alreadyAdmitted)
    case .preparing, .downloading, .verifying: return .hold(.inFlight)
    case .cancelled: return inputs.userInitiated ? .start : .hold(.cancelledByUser)
    // A failed attempt retries on the next discrete trigger (launch, onboarding, Parakeet
    // admission, a settings change, Try again), never in a loop.
    case .notReady, .failed: return .start
    }
  }
}
