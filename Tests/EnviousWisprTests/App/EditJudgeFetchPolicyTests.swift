import EnviousWisprModelDelivery
import EnviousWisprPostProcessing
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// When the correction judge may download (#996 phase D). When this fails, a
/// Mac downloads 323 MB for a package no exam passed, during first-run setup,
/// behind a tester's Debug door, or against a kill switch.
@Suite(
  "EditJudgeFetchPolicy — five gates, then the judge's own state (#996 phase D)",
  .tags(.productOutcome))
struct EditJudgeFetchPolicyTests {
  private func inputs(
    qualified: Bool = true, onboarding: Bool = true, parakeet: Bool = true, door: Bool = false,
    killSwitch: Bool = true, state: DeliveryState = .notReady, userInitiated: Bool = false
  ) -> EditJudgeFetchPolicy.Inputs {
    EditJudgeFetchPolicy.Inputs(
      classifierQualifiedSomewhere: qualified, onboardingComplete: onboarding,
      parakeetAdmitted: parakeet, debugDoorPresent: door, killSwitchOn: killSwitch,
      judgeState: state, userInitiated: userInitiated)
  }

  @Test("every gate open and nothing installed starts the download")
  func starts() {
    #expect(EditJudgeFetchPolicy.decide(inputs()) == .start)
    #expect(
      EditJudgeFetchPolicy.decide(
        inputs(state: .failed(DeliveryFailure(reason: .sourceUnreachable)))) == .start)
  }

  @Test("each closed gate holds with its own reason, in gate order")
  func gates() {
    #expect(EditJudgeFetchPolicy.decide(inputs(qualified: false)) == .hold(.notQualified))
    #expect(EditJudgeFetchPolicy.decide(inputs(onboarding: false)) == .hold(.onboardingIncomplete))
    #expect(EditJudgeFetchPolicy.decide(inputs(parakeet: false)) == .hold(.parakeetNotAdmitted))
    #expect(EditJudgeFetchPolicy.decide(inputs(door: true)) == .hold(.debugDoorPresent))
    #expect(EditJudgeFetchPolicy.decide(inputs(killSwitch: false)) == .hold(.killSwitchOff))
    // Qualification is the FIRST gate: an unqualified package never downloads
    // however open the rest are.
    #expect(
      EditJudgeFetchPolicy.decide(inputs(qualified: false, onboarding: false, parakeet: false))
        == .hold(.notQualified))
  }

  @Test("the judge's own delivery state: admitted, in flight and user-cancelled all hold")
  func judgeState() {
    #expect(EditJudgeFetchPolicy.decide(inputs(state: .admitted)) == .hold(.alreadyAdmitted))
    #expect(
      EditJudgeFetchPolicy.decide(inputs(state: .preparing(validatingExistingCache: false)))
        == .hold(.inFlight))
    #expect(
      EditJudgeFetchPolicy.decide(
        inputs(state: .downloading(fractionCompleted: 0.2, bytesWritten: 1, totalBytes: 5)))
        == .hold(.inFlight))
    #expect(EditJudgeFetchPolicy.decide(inputs(state: .verifying)) == .hold(.inFlight))
    #expect(
      EditJudgeFetchPolicy.decide(inputs(state: .cancelled(resumable: true)))
        == .hold(.cancelledByUser))
    // A Download press after the user's own cancel restarts; the gates still apply.
    #expect(
      EditJudgeFetchPolicy.decide(inputs(state: .cancelled(resumable: true), userInitiated: true))
        == .start)
    #expect(
      EditJudgeFetchPolicy.decide(
        inputs(qualified: false, state: .cancelled(resumable: true), userInitiated: true))
        == .hold(.notQualified))
  }

  @Test("the shipped table today qualifies no classifier for the bundled package, so the policy holds everywhere")
  func shippedTableHolds() throws {
    // The bundled manifest names a STAGED, NOT QUALIFIED package (fp16 bar
    // pending); this is the line that keeps every user's download at zero.
    let manifest = try DeliveryManifest.load(
      from: try Data(
        contentsOf: RepoRoot.url.appending(
          path: "Sources/EnviousWispr/Resources/edit-judge-delivery-manifest.json")))
    let digest = try #require(manifest.runtimeIdentityDigest)
    let qualified = CorrectionJudgeArmSelection.classifierIsQualifiedSomewhere(digest: digest)
    #expect(qualified == false)
    #expect(EditJudgeFetchPolicy.decide(inputs(qualified: qualified)) == .hold(.notQualified))
  }
}
