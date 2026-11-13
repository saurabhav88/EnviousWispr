import EnviousWisprCore
import Foundation
import Observation
import Testing

@testable import EnviousWisprAppKit

/// #4528 D4a.1 (plan M83): the facts Downloads and Getting ready show, their recovery actions
/// and the countdown's visibility.
///
/// **Product Outcome.** When this fails, Getting ready shows "loading" forever for a polish model
/// that failed (with no Try again), a polish Try again reaches the wrong model, a person cannot
/// leave Getting ready without AI polish, the screen keeps a frozen bar or slow-network notice
/// because it never redraws, or Downloads jumps onward after it was hidden.
@MainActor
@Suite(.tags(.productOutcome))
struct OnboardingDownloadsPresentationTests {
  typealias P = OnboardingDownloadsPresentation

  @Test("polish preparation: failure, then current readiness, then the transfer phase")
  func preparationMapping() {
    var r = OnboardingReadiness()
    #expect(P.preparation(polish: nil, readiness: r, phase: nil, queued: nil) == .none)
    #expect(P.preparation(polish: "off", readiness: r, phase: nil, queued: nil) == .off)
    #expect(P.preparation(polish: "cloud", readiness: r, phase: nil, queued: nil) == .cloud(passed: false))
    #expect(
      P.preparation(polish: "appleIntelligence", readiness: r, phase: nil, queued: nil)
        == .appleIntelligence(available: false))
    #expect(P.preparation(polish: "eg1.mini", readiness: r, phase: .notStarted, queued: "eg1.mini") == .queued)
    #expect(P.preparation(polish: "eg1.mini", readiness: r, phase: .unknown, queued: nil) == .waiting)
    // Missing and idle: just requested this visit waits; nobody asked (a relaunch after a disk
    // refusal) shows the stopped card with its recovery actions, never an endless start (D6).
    #expect(
      P.preparation(
        polish: "eg1.mini", readiness: r, phase: .notStarted, queued: nil, startRequested: true)
        == .waiting)
    #expect(P.preparation(polish: "eg1.mini", readiness: r, phase: .notStarted, queued: nil) == .downloadStopped)
    #expect(P.preparation(polish: "eg1.mini", readiness: r, phase: .downloading(fraction: 0.4), queued: nil) == .downloading)
    #expect(P.preparation(polish: "eg1.mini", readiness: r, phase: .verifying, queued: nil) == .downloading)
    #expect(P.preparation(polish: "eg1.mini", readiness: r, phase: .paused, queued: nil) == .downloadStopped)
    #expect(P.preparation(polish: "eg1.mini", readiness: r, phase: .unavailable, queued: nil) == .downloadStopped)
    #expect(P.preparation(polish: "eg1.mini", readiness: r, phase: .installed, queued: nil) == .loading)
    // Readiness for ANOTHER pick never counts.
    r.polish = "eg1.full"
    r.polishReady = true
    #expect(P.preparation(polish: "eg1.mini", readiness: r, phase: .installed, queued: nil) == .loading)
    r.polish = "eg1.mini"
    #expect(P.preparation(polish: "eg1.mini", readiness: r, phase: .installed, queued: nil) == .ready)
    r.polishReady = false
    r.polishFailed = true
    #expect(P.preparation(polish: "eg1.mini", readiness: r, phase: .installed, queued: nil) == .failed)
    r.polish = "cloud"
    r.polishFailed = false
    r.polishReady = true
    #expect(P.preparation(polish: "cloud", readiness: r, phase: nil, queued: nil) == .cloud(passed: true))
  }

  @Test("Getting ready: continue without AI polish keeps speech and permission readiness required")
  func continueWithoutPolish() {
    var s = OnboardingFlowState()
    s.step = .gettingReady
    s.choices = OnboardingChoices(languageMode: .auto, speech: .parakeet, polish: "eg1.mini")
    s.readiness = OnboardingReadiness(
      speech: .parakeet, polish: "eg1.mini", speechInstalled: true, engineWarm: false,
      polishReady: false, polishFailed: true, microphoneGranted: true, accessibilityGranted: true)
    // Speech not warm: polish turns off, the person stays on Getting ready.
    var t = OnboardingFlow.reduce(s, .continueWithoutPolish)
    #expect(t.state.step == .gettingReady && t.state.choices.polish == OnboardingChoices.polishOff)
    #expect(t.outcome == .noOp, "staying put is a saved choice change, not a move")
    #expect(t.state.readiness.polishFailed == false && t.effects == [.persistCheckpoint])
    // Speech warm and both grants: off goes straight to Practice.
    s.readiness.engineWarm = true
    t = OnboardingFlow.reduce(s, .continueWithoutPolish)
    #expect(t.state.step == .practice)
    // A revoked grant still blocks Practice; Review permissions leads back.
    s.readiness.accessibilityGranted = false
    t = OnboardingFlow.reduce(s, .continueWithoutPolish)
    #expect(t.state.step == .gettingReady)
    #expect(OnboardingFlow.reduce(t.state, .reviewPermissions).state.step == .permissions)
    // Neither event moves any other step.
    var other = s
    other.step = .downloads
    #expect(OnboardingFlow.reduce(other, .continueWithoutPolish).outcome == .noOp)
    #expect(OnboardingFlow.reduce(other, .reviewPermissions).outcome == .noOp)
  }

  @Test("a failed local polish load is reported, and Try again reaches only the current model's activation")
  func polishFailureAndRetry() async {
    let world = OnboardingCoordinatorTests.World()
    world.speechPhase[.parakeet] = .installed
    world.polishPhase[.egOne(.mini)] = .installed
    let c = OnboardingRuntimeTests.atDownloads(world)
    #expect(c.state.choices.polish == "eg1.mini")
    // Loading: installed, helper not ready, not failing.
    world.local[.egOne(.mini)] = OnboardingLocalPolishState(installed: true, serverReady: false, healthy: true)
    c.refreshReadiness()
    await c.settle()
    #expect(c.state.readiness.polishFailed == false && c.state.readiness.polishReady == false)
    let before = world.log.count
    c.retryPolish()
    await c.settle()
    #expect(!world.log.dropFirst(before).contains { $0.hasPrefix("activate(") }, "Try again ran while still loading")
    // The owner reports a failed load.
    world.local[.egOne(.mini)] = OnboardingLocalPolishState(installed: true, serverReady: false, healthy: false)
    c.refreshReadiness()
    await c.settle()
    #expect(c.state.readiness.polishFailed)
    c.retryPolish()
    await c.settle()
    #expect(world.log.dropFirst(before).filter { $0 == "activate(egOne.mini)" }.count == 1)
  }

  @Test("observation redraws on the coordinator's and runtime's presentation facts")
  func presentationFactsAreObservable() async {
    let world = OnboardingCoordinatorTests.World()
    let c = OnboardingRuntimeTests.atDownloads(world)
    await c.settle()
    final class Flag: @unchecked Sendable { var fired = false }  // single-touch test flag
    let stateChanged = Flag()
    withObservationTracking { _ = c.state } onChange: { stateChanged.fired = true }
    c.send(.next)
    #expect(stateChanged.fired, "a step change did not reach an observing view")

    let facts = OnboardingRuntimeTests.Facts()
    var now = OnboardingRuntimeTests.t0
    let r = OnboardingRuntimeTests.runtime(world, c, facts, clock: { now })
    c.send(.back)  // Downloads again
    r.start()
    r.setDownloadsScreenVisible(true)
    r.tick()
    let counting = Flag()
    withObservationTracking { _ = r.isCountingDown } onChange: { counting.fired = true }
    facts.finished = true
    now += 0.5
    r.tick()
    #expect(r.isCountingDown && counting.fired, "the countdown never reached an observing view")
    r.stop()
  }
}
