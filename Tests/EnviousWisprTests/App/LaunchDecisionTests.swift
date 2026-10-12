import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #3252, plan 3.2 / T1: what the launch does about the move offer. When one of these fails the
/// person sees the offer at the wrong time: not at all on a download copy that needs it, or again
/// on a copy that already said "Not Now" this week. Expected values are literals; the seven-day
/// figure is typed here, not read from the production constant.
@MainActor
@Suite("LaunchDecision (#3252)", .tags(.productOutcome))
struct LaunchDecisionTests {

  private static let now = Date(timeIntervalSince1970: 2_000_000)
  private static let sevenDays: TimeInterval = 604_800

  private func decide(
    child: Bool = false, state: ApplicationLocationState,
    declined secondsAgo: TimeInterval? = nil, declinedVersion: String = "2.5.3",
    version: String = "2.5.3"
  ) -> LaunchDecision {
    LaunchDecision.decide(
      isRelaunchChild: child, state: state,
      lastDecline: secondsAgo.map {
        (at: Self.now.addingTimeInterval(-$0), version: declinedVersion)
      },
      currentVersion: version, now: Self.now)
  }

  @Test("A relaunched child always proceeds, whatever its location says")
  func childPrecedence() {
    for state in [
      ApplicationLocationState.healthy, .translocated, .readOnlyVolume, .detectionFailed,
    ] {
      #expect(decide(child: true, state: state) == .proceed, "\(state)")
    }
  }

  @Test("A location that does not block updates proceeds, with or without a decline")
  func nonBlockingProceeds() {
    for state in [ApplicationLocationState.healthy, .detectionFailed] {
      #expect(decide(state: state) == .proceed, "\(state)")
      #expect(decide(state: state, declined: 10) == .proceed, "\(state)")
    }
  }

  @Test("A blocking location with no decline offers first, for both blocking states")
  func blockingWithNoDeclineOffers() {
    #expect(decide(state: .translocated) == .offerFirst(state: .translocated))
    #expect(decide(state: .readOnlyVolume) == .offerFirst(state: .readOnlyVolume))
  }

  @Test(
    "Cooldown boundary: one second before seven days proceeds, exactly seven days and after offer",
    arguments: [
      (604_799.0, false), (604_800.0, true), (604_801.0, true), (0.0, false), (60.0, false),
    ])
  func cooldownBoundary(secondsSinceDecline: TimeInterval, offers: Bool) {
    let result = decide(state: .translocated, declined: secondsSinceDecline)
    #expect(result == (offers ? .offerFirst(state: .translocated) : .proceed))
  }

  @Test("A decline from a different version does not suppress the offer")
  func versionChangeOffersAgain() {
    #expect(
      decide(state: .translocated, declined: 60, declinedVersion: "2.5.2", version: "2.5.3")
        == .offerFirst(state: .translocated))
    #expect(
      decide(state: .translocated, declined: 60, declinedVersion: "2.5.3", version: "2.5.3")
        == .proceed)
  }

  // MARK: One cadence owner, no persistence side effects

  @Test("The shared cadence rule and the coordinator's decision agree at the boundary")
  func cadenceRuleAgreesWithTheDecision() {
    for (seconds, offers) in [(Self.sevenDays - 1, false), (Self.sevenDays, true)] {
      let suppression = ApplicationRelocationCoordinatorTests.FakeSuppression()
      suppression.stored = (Self.now.addingTimeInterval(-seconds), "2.3.0")
      let h = ApplicationRelocationCoordinatorTests.makeHarness(
        bundleURL: ApplicationRelocationCoordinatorTests.translocatedURL, now: Self.now,
        suppression: suppression)
      #expect(
        ApplicationRelocationCoordinator.offerIsDue(
          lastDecline: suppression.stored, currentVersion: "2.3.0", now: Self.now) == offers)
      #expect(
        h.coordinator.launchDecision() == (offers ? .offerFirst(state: .translocated) : .proceed))
    }
  }

  @Test("Evaluating the decision reads the record and writes nothing")
  func decisionHasNoPersistenceSideEffects() {
    let suppression = ApplicationRelocationCoordinatorTests.FakeSuppression()
    let decline = (at: Self.now.addingTimeInterval(-60), version: "2.3.0")
    suppression.stored = decline
    // Healthy: the stale-decline clearing belongs to reportLaunchState, never to the decision.
    let healthy = ApplicationRelocationCoordinatorTests.makeHarness(
      bundleURL: ApplicationRelocationCoordinatorTests.healthyURL, now: Self.now,
      suppression: suppression)
    #expect(healthy.coordinator.launchDecision() == .proceed)
    #expect(suppression.clearCount == 0)
    #expect(suppression.stored?.version == "2.3.0")
    // Blocked inside the cooldown: proceeds and keeps the record.
    let blocked = ApplicationRelocationCoordinatorTests.makeHarness(
      bundleURL: ApplicationRelocationCoordinatorTests.translocatedURL, now: Self.now,
      suppression: suppression)
    #expect(blocked.coordinator.launchDecision() == .proceed)
    #expect(suppression.clearCount == 0)
    #expect(suppression.stored?.version == "2.3.0")
  }

  @Test("A relaunched child's coordinator decides proceed even from a blocked location")
  func childCoordinatorProceeds() {
    let h = ApplicationRelocationCoordinatorTests.makeHarness(
      bundleURL: ApplicationRelocationCoordinatorTests.translocatedURL,
      relaunchAttemptID: "attempt-9")
    #expect(h.coordinator.launchDecision() == .proceed)
  }
}
