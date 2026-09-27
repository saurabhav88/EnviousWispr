import EnviousWisprModelDelivery
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// When the word check may download (#3242). When this fails, a Mac downloads about 440 MB it
/// will never use (the Dictionary is off, or every chosen engine has its own check), during
/// first-run setup, or against the kill switch; or an Apple Intelligence user never gets it.
@Suite(
  "WordCheckFetchPolicy: Dictionary, need, setup, kill switch, then the model's own state (#3242)",
  .tags(.productOutcome))
struct WordCheckFetchPolicyTests {
  private func inputs(
    dictionary: Bool = true, needed: Bool = true, onboarding: Bool = true, parakeet: Bool = true,
    killSwitch: Bool = true, state: DeliveryState = .notReady, userInitiated: Bool = false
  ) -> WordCheckFetchPolicy.Inputs {
    .init(
      dictionaryEnabled: dictionary, someEngineLacksOwnChecker: needed,
      onboardingComplete: onboarding, parakeetAdmitted: parakeet, killSwitchOn: killSwitch,
      state: state, userInitiated: userInitiated)
  }

  @Test("every gate open and nothing installed starts the download; a failed one retries")
  func starts() {
    #expect(WordCheckFetchPolicy.decide(inputs()) == .start)
    #expect(
      WordCheckFetchPolicy.decide(inputs(state: .failed(DeliveryFailure(reason: .sourceUnreachable))))
        == .start)
  }

  @Test("each closed gate holds with its own reason, in gate order")
  func gates() {
    #expect(WordCheckFetchPolicy.decide(inputs(dictionary: false)) == .hold(.dictionaryOff))
    #expect(WordCheckFetchPolicy.decide(inputs(needed: false)) == .hold(.notNeeded))
    #expect(WordCheckFetchPolicy.decide(inputs(onboarding: false)) == .hold(.onboardingIncomplete))
    #expect(WordCheckFetchPolicy.decide(inputs(parakeet: false)) == .hold(.parakeetNotAdmitted))
    #expect(WordCheckFetchPolicy.decide(inputs(killSwitch: false)) == .hold(.killSwitchOff))
    // The Dictionary switch is the founder's one off-switch: it wins over every other reason.
    #expect(
      WordCheckFetchPolicy.decide(inputs(dictionary: false, needed: false, killSwitch: false))
        == .hold(.dictionaryOff))
  }

  @Test("an installed or in-flight model is left alone; a user's cancel holds until they ask again")
  func state() {
    #expect(WordCheckFetchPolicy.decide(inputs(state: .admitted)) == .hold(.alreadyAdmitted))
    #expect(WordCheckFetchPolicy.decide(inputs(state: .downloading(fractionCompleted: 0.2, bytesWritten: 1, totalBytes: 5))) == .hold(.inFlight))
    #expect(WordCheckFetchPolicy.decide(inputs(state: .cancelled(resumable: true))) == .hold(.cancelledByUser))
    #expect(WordCheckFetchPolicy.decide(inputs(state: .cancelled(resumable: true), userInitiated: true)) == .start)
  }
}
