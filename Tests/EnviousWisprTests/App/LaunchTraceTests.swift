import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #3252, plan 3a / T5: the order of a healthy launch as the sequencer sees it, against a fake
/// target that records each call. The expected list is typed out, taken from the pinned baseline
/// `docs/audits/3252-spike-runs/S5-baseline-healthy.trace`, with the delegate attach and the scene
/// evaluation left out: those happen outside the sequencer and belong to the AppLive integration
/// trace that Chunk 4 records. This suite proves the lifecycle contract the sequencer owns; it
/// does not prove the real app starts in this order, and it says nothing about release builds.
@MainActor
@Suite("Launch order trace (#3252)", .tags(.driftGuard))
struct LaunchTraceTests {

  private static let healthyOrder = [
    "target construction requested",
    "target constructed",
    "will-finish forwarded",
    "did-finish forwarded",
    "activation",
    "reopen",
    "termination",
  ]

  /// Maps the fake target's own words to the oracle's words so the literal reads like the plan.
  private static func named(_ events: [String]) -> [String] {
    events.map {
      switch $0 {
      case "construction requested": "target construction requested"
      case "target constructed": "target constructed"
      case "will": "will-finish forwarded"
      case "did": "did-finish forwarded"
      case "active": "activation"
      case "reopen": "reopen"
      case "terminate": "termination"
      default: "UNEXPECTED \($0)"
      }
    }
  }

  @Test("A healthy launch: construct, will, did, activation, reopen, termination")
  func healthyLaunchOrder() {
    let log = SequencerEventLog()
    let sequencer = LaunchSequencer<SequencerFakeTarget>(startImmediately: true) {
      log.add("construction requested")
      return SequencerFakeTarget(log: log)
    }
    sequencer.applicationWillFinishLaunching()
    sequencer.applicationDidFinishLaunching()
    sequencer.applicationDidBecomeActive()
    _ = sequencer.applicationShouldHandleReopen()
    sequencer.applicationWillTerminate()
    #expect(Self.named(log.events) == Self.healthyOrder)
  }

  @Test("An offer-first launch that continues ends in the same order once it starts")
  func offerFirstContinuationOrder() {
    let log = SequencerEventLog()
    let sequencer = LaunchSequencer<SequencerFakeTarget>(startImmediately: false) {
      log.add("construction requested")
      return SequencerFakeTarget(log: log)
    }
    // The system delivers will, did and an activation while the offer is up; none reaches a target.
    sequencer.applicationWillFinishLaunching()
    sequencer.applicationDidFinishLaunching()
    sequencer.applicationDidBecomeActive()
    #expect(log.events.isEmpty)
    sequencer.startNormally()
    _ = sequencer.applicationShouldHandleReopen()
    sequencer.applicationWillTerminate()
    #expect(Self.named(log.events) == Self.healthyOrder)
  }

  @Test("The oracle itself rejects a launch that skips a step")
  func oracleControl() {
    let log = SequencerEventLog()
    let sequencer = LaunchSequencer<SequencerFakeTarget>(startImmediately: true) {
      log.add("construction requested")
      return SequencerFakeTarget(log: log)
    }
    sequencer.applicationDidFinishLaunching()
    sequencer.applicationWillTerminate()
    #expect(Self.named(log.events) != Self.healthyOrder)
  }
}
