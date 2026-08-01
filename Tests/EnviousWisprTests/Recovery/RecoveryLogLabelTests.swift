import Testing

@testable import EnviousWisprAppKit

/// #1762. Freezes the outcome vocabulary recovery writes to the local debug log.
///
/// These strings are the on-machine oracle. Recovery previously wrote NOTHING,
/// so a replay-and-delete of an orphan that held no speech was indistinguishable
/// from "recovery is broken" — an hour of live diagnosis and one falsely filed
/// bug (#1760), and the reason #1813's cause had to be inferred from aggregate
/// telemetry across 50 users rather than reproduced on one machine.
///
/// Every test carries a NEGATIVE arm. A label function returning one string for
/// everything would satisfy "not empty" while destroying the only property that
/// matters: that two different outcomes read differently.
/// `@MainActor` to match `RecoveryCoordinatorTests` — `RecoveryCoordinator` is a
/// MainActor type, so its statics inherit that isolation.
@MainActor
@Suite struct RecoveryLogLabelTests {

  /// Every outcome the replayer can return. Written out rather than derived so
  /// adding a case to `RecoveryReplayOutcome` fails to compile here until it is
  /// listed — the label switch is exhaustive, but nothing would otherwise force
  /// this test to cover a new member.
  private static let allOutcomes: [RecoveryReplayOutcome] = [
    .recovered,
    .abandoned,
    .failed(.unrecoverable),
    .failed(.save(.other)),
    .aborted,
    .deferred,
    .deferredMarkerClearFailed,
  ]

  @Test("every outcome reads differently in the log")
  func labelsAreDistinct() {
    let labels = Self.allOutcomes.map(RecoveryCoordinator.logLabel)

    // THE POINT. A shared label would put "recovered" and "gave up" on the same
    // line, which is exactly the ambiguity #1762 exists to remove.
    #expect(Set(labels).count == labels.count, "two outcomes share a log label")

    for label in labels {
      #expect(!label.isEmpty)
    }
  }

  @Test("the two outcomes that looked identical on disk now read differently")
  func successAndGiveUpAreDistinguishable() {
    // Both delete the spool, so after the fact the disk is byte-identical. The
    // log line is the ONLY thing that separates them.
    let recovered = RecoveryCoordinator.logLabel(.recovered)
    let gaveUp = RecoveryCoordinator.logLabel(.failed(.unrecoverable))

    #expect(recovered != gaveUp)
    #expect(recovered.contains("recovered"))
    #expect(gaveUp.contains("unrecoverable"))

    // NEGATIVE: the give-up label must not read as a success. A future edit that
    // softened it to "recovery finished" would pass a distinctness check and
    // still mislead the person reading the log at 1am.
    #expect(!gaveUp.contains("saved to History"))
  }

  @Test("a deferral says no attempt ran, because that decides whether audio survives")
  func deferralsSayNoAttemptRan() {
    // `shouldDeleteAfterReplay` retains on both deferrals: ASR never ran, so the
    // one attempt is unspent. The label has to carry that, or a reader sees
    // "deferred" and cannot tell whether the recording is still on disk.
    for outcome: RecoveryReplayOutcome in [.deferred, .deferredMarkerClearFailed] {
      #expect(RecoveryCoordinator.logLabel(outcome).contains("deferred"))
      #expect(RecoveryCoordinator.shouldDeleteAfterReplay(outcome) == false)
    }

    // TWO-WAY CONTROL: a spent attempt must still delete. Without this arm, a
    // change that made everything retain would pass the assertions above while
    // breaking the one-attempt rule.
    #expect(RecoveryCoordinator.shouldDeleteAfterReplay(.failed(.unrecoverable)) == true)
  }

  @Test("no label leaks anything but the outcome")
  func labelsCarryNoContent() {
    // `RecoveryLog`'s rule: counts, outcomes and closed-vocabulary labels only.
    // These strings are constants, so the freeze is that they STAY constants —
    // no id, path, or interpolated payload creeping in later.
    for label in Self.allOutcomes.map(RecoveryCoordinator.logLabel) {
      #expect(!label.contains("/"), "a path reached a log label")
      #expect(!label.contains("-"), "an identifier reached a log label")
    }
  }
}
