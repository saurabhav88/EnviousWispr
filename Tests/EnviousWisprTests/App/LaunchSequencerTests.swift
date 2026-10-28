import AppKit
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprServices

// #3252, plan 3.3 / T4 and the production ordering owner of T9. A fake target records every
// call it receives into one shared log; the sequencer, the window hider and the offer driver
// are the real production types. Expected sequences are typed out as literals. Nothing here
// starts the app, shows a card or touches a real window server.

@MainActor
final class SequencerEventLog {
  private(set) var events: [String] = []
  /// Runs right after an event is recorded, so a test can make the target call back into the
  /// sequencer from inside one of its own callbacks.
  var onEvent: (@MainActor (String) -> Void)?
  func add(_ event: String) {
    events.append(event)
    onEvent?(event)
  }
  func count(_ event: String) -> Int { events.filter { $0 == event }.count }
}

@MainActor
final class SequencerFakeTarget: LaunchTarget {
  private let log: SequencerEventLog
  var reopenResult = true
  init(log: SequencerEventLog) {
    self.log = log
    log.add("target constructed")
  }
  func applicationWillFinishLaunching() { log.add("will") }
  func applicationDidFinishLaunching() { log.add("did") }
  func applicationDidBecomeActive() { log.add("active") }
  func applicationShouldHandleReopen() -> Bool {
    log.add("reopen")
    return reopenResult
  }
  /// What the fake answers when asked whether to quit now.
  var quitNow = true
  func applicationShouldTerminate(reply: @escaping @MainActor (Bool) -> Void) -> Bool {
    log.add("shouldTerminate")
    return quitNow
  }
  func applicationWillTerminate() { log.add("terminate") }
}

@MainActor
private final class SequencerBox {
  var sequencer: LaunchSequencer<SequencerFakeTarget>?
  var reentrantResult: Bool?
}

@MainActor
private func makeSequencer(
  startImmediately: Bool, log: SequencerEventLog, box: SequencerBox = SequencerBox(),
  duringConstruction: (@MainActor () -> Void)? = nil
) -> LaunchSequencer<SequencerFakeTarget> {
  let sequencer = LaunchSequencer<SequencerFakeTarget>(startImmediately: startImmediately) {
    log.add("construction requested")
    duringConstruction?()
    return SequencerFakeTarget(log: log)
  }
  box.sequencer = sequencer
  return sequencer
}

@MainActor
@Suite("LaunchSequencer (#3252)", .tags(.productOutcome))
struct LaunchSequencerTests {

  // MARK: Quit (#4086)

  @Test("Quit before the app was built quits at once and asks no target; afterwards the target answers")
  func quitAsksOnlyARunningTarget() {
    let log = SequencerEventLog()
    let waiting = makeSequencer(startImmediately: false, log: log)
    #expect(waiting.applicationShouldTerminate { _ in Issue.record("no reply is owed") })
    #expect(log.events.isEmpty)

    let started = makeSequencer(startImmediately: true, log: log)
    started.target?.quitNow = false
    #expect(started.applicationShouldTerminate { _ in } == false)
    #expect(log.count("shouldTerminate") == 1)
  }

  // MARK: Immediate and deferred construction

  @Test("A healthy launch builds the target inside init and forwards one to one")
  func immediateConstruction() {
    let log = SequencerEventLog()
    let sequencer = makeSequencer(startImmediately: true, log: log)
    #expect(sequencer.phase == .started)
    #expect(log.events == ["construction requested", "target constructed"])
    sequencer.applicationWillFinishLaunching()
    sequencer.applicationDidFinishLaunching()
    sequencer.applicationDidBecomeActive()
    #expect(sequencer.applicationShouldHandleReopen() == true)
    sequencer.applicationWillTerminate()
    #expect(
      log.events == [
        "construction requested", "target constructed", "will", "did", "active", "reopen",
        "terminate",
      ])
    #expect(sequencer.phase == .terminal)
  }

  @Test("An offer-first launch leaves the target absent and the gate closed")
  func deferredConstruction() {
    let log = SequencerEventLog()
    let sequencer = makeSequencer(startImmediately: false, log: log)
    #expect(sequencer.phase == .waiting)
    #expect(sequencer.target == nil)
    #expect(log.events.isEmpty)
  }

  @Test("Held will and did are delivered once each, in order, after the target is built")
  func heldCallbacksDeliveredOnceInOrder() {
    let log = SequencerEventLog()
    let sequencer = makeSequencer(startImmediately: false, log: log)
    sequencer.applicationWillFinishLaunching()
    sequencer.applicationWillFinishLaunching()
    sequencer.applicationDidFinishLaunching()
    sequencer.applicationDidFinishLaunching()
    #expect(log.events.isEmpty)
    #expect(sequencer.startNormally() == true)
    #expect(log.events == ["construction requested", "target constructed", "will", "did"])
    #expect(sequencer.phase == .started)
    #expect(sequencer.target != nil)
  }

  // MARK: Start rules

  @Test("A repeated start builds nothing more and reports false")
  func repeatedStart() {
    let log = SequencerEventLog()
    let sequencer = makeSequencer(startImmediately: false, log: log)
    #expect(sequencer.startNormally() == true)
    #expect(sequencer.startNormally() == false)
    #expect(log.count("construction requested") == 1)
  }

  @Test("A start requested while construction is running is refused")
  func reentrantStart() {
    let log = SequencerEventLog()
    let box = SequencerBox()
    let sequencer = makeSequencer(startImmediately: false, log: log, box: box) {
      box.reentrantResult = box.sequencer?.startNormally()
    }
    #expect(sequencer.startNormally() == true)
    #expect(box.reentrantResult == false)
    #expect(log.count("construction requested") == 1)
    #expect(sequencer.phase == .started)
  }

  @Test("Termination while waiting makes it terminal and nothing is ever built")
  func terminationWhileWaiting() {
    let log = SequencerEventLog()
    let sequencer = makeSequencer(startImmediately: false, log: log)
    sequencer.applicationWillFinishLaunching()
    sequencer.applicationWillTerminate()
    #expect(sequencer.phase == .terminal)
    #expect(sequencer.startNormally() == false)
    #expect(log.events.isEmpty)
    #expect(sequencer.target == nil)
  }

  @Test("Termination during construction suppresses the launch callbacks and ends the target once")
  func terminationDuringConstruction() {
    let log = SequencerEventLog()
    let box = SequencerBox()
    let sequencer = makeSequencer(startImmediately: false, log: log, box: box) {
      box.sequencer?.applicationWillTerminate()
    }
    sequencer.applicationWillFinishLaunching()
    sequencer.applicationDidFinishLaunching()
    #expect(sequencer.startNormally() == false)
    #expect(log.events == ["construction requested", "target constructed", "terminate"])
    #expect(sequencer.phase == .terminal)
    // Terminal: nothing starts again, and the target is not told twice.
    #expect(sequencer.startNormally() == false)
    sequencer.applicationWillTerminate()
    #expect(log.count("terminate") == 1)
  }

  @Test(
    "Termination reported from inside a held or replayed callback ends the launch there",
    arguments: [
      // The callback that asks to terminate, and what the target must have heard by then.
      ("will", ["construction requested", "target constructed", "will", "terminate"]),
      ("did", ["construction requested", "target constructed", "will", "did", "terminate"]),
      (
        "active",
        [
          "construction requested", "target constructed", "will", "did", "active", "terminate",
        ]
      ),
    ])
  func terminationFromInsideAHeldCallback(trigger: String, expected: [String]) {
    let log = SequencerEventLog()
    let sequencer = makeSequencer(startImmediately: false, log: log)
    sequencer.applicationWillFinishLaunching()
    sequencer.applicationDidFinishLaunching()
    sequencer.applicationDidBecomeActive()
    log.onEvent = { event in
      if event == trigger { sequencer.applicationWillTerminate() }
    }
    #expect(sequencer.startNormally() == false, "\(trigger)")
    #expect(sequencer.phase == .terminal, "\(trigger)")
    #expect(log.events == expected, "\(trigger)")
    // Terminal means nothing more reaches the target, and it is told once.
    sequencer.applicationDidBecomeActive()
    sequencer.applicationDidFinishLaunching()
    sequencer.applicationWillTerminate()
    #expect(sequencer.startNormally() == false, "\(trigger)")
    #expect(log.events == expected, "\(trigger)")
    #expect(log.count("terminate") == 1, "\(trigger)")
  }

  @Test("Termination reported from inside the direct did-finish forward stops the replay")
  func terminationFromInsideADirectDidFinish() {
    let log = SequencerEventLog()
    let sequencer = makeSequencer(startImmediately: false, log: log)
    sequencer.applicationDidBecomeActive()
    sequencer.startNormally()
    log.onEvent = { event in
      if event == "did" { sequencer.applicationWillTerminate() }
    }
    sequencer.applicationDidFinishLaunching()
    #expect(sequencer.phase == .terminal)
    // The held activation is not replayed into a target that is already told to terminate.
    #expect(
      log.events == ["construction requested", "target constructed", "did", "terminate"])
  }

  @Test("A hand-off is terminal: no start afterwards, nothing built")
  func handOffIsTerminal() {
    let log = SequencerEventLog()
    let sequencer = makeSequencer(startImmediately: false, log: log)
    sequencer.handOff()
    #expect(sequencer.phase == .terminal)
    #expect(sequencer.startNormally() == false)
    #expect(log.events.isEmpty)
  }

  @Test("A hand-off after the app started changes nothing")
  func handOffAfterStartIsIgnored() {
    let log = SequencerEventLog()
    let sequencer = makeSequencer(startImmediately: true, log: log)
    sequencer.handOff()
    #expect(sequencer.phase == .started)
  }

  // MARK: No target yet

  @Test("An absent target is never forwarded to, and reopen returns true")
  func absentTargetReceivesNothing() {
    let log = SequencerEventLog()
    let sequencer = makeSequencer(startImmediately: false, log: log)
    #expect(sequencer.applicationShouldHandleReopen() == true)
    sequencer.applicationDidBecomeActive()
    #expect(log.events.isEmpty)
  }

  @Test("Reopen after the start returns the target's own answer")
  func reopenAfterStartForwards() {
    let log = SequencerEventLog()
    let sequencer = makeSequencer(startImmediately: false, log: log)
    sequencer.startNormally()
    sequencer.target?.reopenResult = false
    #expect(sequencer.applicationShouldHandleReopen() == false)
  }

  // MARK: Missed activations

  @Test("Several activations while waiting are one, replayed once after did")
  func missedActivationsCoalesce() {
    let log = SequencerEventLog()
    let sequencer = makeSequencer(startImmediately: false, log: log)
    sequencer.applicationWillFinishLaunching()
    sequencer.applicationDidFinishLaunching()
    sequencer.applicationDidBecomeActive()
    sequencer.applicationDidBecomeActive()
    sequencer.applicationDidBecomeActive()
    sequencer.startNormally()
    #expect(
      log.events == ["construction requested", "target constructed", "will", "did", "active"])
  }

  @Test("A missed activation waits for did-finish launching when did has not arrived yet")
  func missedActivationWaitsForDid() {
    let log = SequencerEventLog()
    let sequencer = makeSequencer(startImmediately: false, log: log)
    sequencer.applicationWillFinishLaunching()
    sequencer.applicationDidBecomeActive()
    sequencer.startNormally()
    #expect(log.events == ["construction requested", "target constructed", "will"])
    sequencer.applicationDidFinishLaunching()
    #expect(
      log.events == ["construction requested", "target constructed", "will", "did", "active"])
  }

  @Test("No missed activation is replayed after termination or after a hand-off")
  func noReplayAfterTerminalStates() {
    for terminal in ["terminate", "handOff"] {
      let log = SequencerEventLog()
      let sequencer = makeSequencer(startImmediately: false, log: log)
      sequencer.applicationDidFinishLaunching()
      sequencer.applicationDidBecomeActive()
      if terminal == "terminate" {
        sequencer.applicationWillTerminate()
      } else {
        sequencer.handOff()
      }
      #expect(sequencer.startNormally() == false, "\(terminal)")
      #expect(log.events.isEmpty, "\(terminal)")
    }
  }

  @Test("After the start, every activation is forwarded as it arrives")
  func ordinaryActivationForwarding() {
    let log = SequencerEventLog()
    let sequencer = makeSequencer(startImmediately: false, log: log)
    sequencer.startNormally()
    sequencer.applicationDidBecomeActive()
    sequencer.applicationDidBecomeActive()
    #expect(log.count("active") == 2)
  }

  // MARK: The window hider (mechanics only; the real rendering check is Chunk 4)

  private func makeWindow(alpha: CGFloat = 1, ignoresMouse: Bool = false) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: [.borderless],
      backing: .buffered, defer: true)
    window.alphaValue = alpha
    window.ignoresMouseEvents = ignoresMouse
    return window
  }

  @Test("The hider hides, then puts back the values the window really had")
  func hiderRestoresOriginalValues() {
    let hider = LaunchWindowHider()
    let window = makeWindow(alpha: 0.5, ignoresMouse: true)
    let owner = NSObject()
    hider.hide(window, owner: owner)
    #expect(window.alphaValue == 0)
    #expect(window.ignoresMouseEvents == true)
    hider.release(window, owner: owner)
    #expect(window.alphaValue == 0.5)
    #expect(window.ignoresMouseEvents == true)
    #expect(hider.hiddenWindowCount == 0)
  }

  @Test("A window shared by two placeholders is restored only when the last one lets go")
  func hiderKeepsHiddenUntilLastOwnerReleases() {
    let hider = LaunchWindowHider()
    let window = makeWindow()
    let first = NSObject()
    let second = NSObject()
    hider.hide(window, owner: first)
    hider.hide(window, owner: second)
    hider.release(window, owner: first)
    #expect(window.alphaValue == 0)
    #expect(window.ignoresMouseEvents == true)
    hider.release(window, owner: second)
    #expect(window.alphaValue == 1)
    #expect(window.ignoresMouseEvents == false)
  }

  @Test("A second hide never records the hidden state as the original")
  func hiderDoesNotOverwriteTheOriginal() {
    let hider = LaunchWindowHider()
    let window = makeWindow(alpha: 0.8)
    let first = NSObject()
    let second = NSObject()
    hider.hide(window, owner: first)
    hider.hide(window, owner: second)
    hider.release(window, owner: second)
    hider.release(window, owner: first)
    #expect(window.alphaValue == 0.8)
  }

  @Test("Releasing an owner that never hid, or another window, changes nothing")
  func hiderIgnoresStrangers() {
    let hider = LaunchWindowHider()
    let hidden = makeWindow()
    let other = makeWindow(alpha: 0.7)
    let owner = NSObject()
    hider.hide(hidden, owner: owner)
    hider.release(other, owner: owner)
    hider.release(hidden, owner: NSObject())
    #expect(other.alphaValue == 0.7)
    #expect(hidden.alphaValue == 0)
    hider.release(hidden, owner: owner)
    #expect(hidden.alphaValue == 1)
  }

  @Test("The placeholder view hides the window it is mounted in and restores it when released")
  func placeholderViewHidesAndRestores() {
    let window = makeWindow(alpha: 0.9)
    let view = LaunchWindowHiderNSView()
    window.contentView = view
    #expect(window.alphaValue == 0)
    #expect(window.ignoresMouseEvents == true)
    view.releaseHiddenWindow()
    #expect(window.alphaValue == 0.9)
    #expect(window.ignoresMouseEvents == false)
  }
}

// MARK: - The offer driver: the order of answer, start, card (T9) and the early observability

@MainActor
private final class DriverRig {
  let log = SequencerEventLog()
  let box = SequencerBox()
  let sequencer: LaunchSequencer<SequencerFakeTarget>
  var outcome: PreflightOutcome
  var queue: [@MainActor () async -> Void] = []
  var preflightStates: [ApplicationLocationState] = []
  var onPreflight: (@MainActor () -> Void)?
  private(set) var driver: LaunchOfferDriver<SequencerFakeTarget>!

  init(outcome: PreflightOutcome, state: ApplicationLocationState = .translocated) {
    self.outcome = outcome
    sequencer = makeSequencer(startImmediately: false, log: log, box: box)
    driver = LaunchOfferDriver(
      sequencer: sequencer, state: state,
      steps: LaunchOfferDriver<SequencerFakeTarget>.Steps(
        prepareObservability: { [unowned self] in log.add("prepare observability") },
        runPreflight: { [unowned self] state in
          log.add("preflight")
          preflightStates.append(state)
          onPreflight?()
          return self.outcome
        },
        presentFailure: { [unowned self] card in log.add("card \(card.failure.rawValue)") },
        schedule: { [unowned self] work in queue.append(work) }))
  }

  /// Runs one scheduled block under a deadline, so a block that never ends is a failure here
  /// and not a parked test.
  func runBounded(_ work: @escaping @MainActor () async -> Void) async {
    let run = Task { @MainActor in await work() }
    if await preflightBoundedValue(of: run) == nil {
      Issue.record("scheduled work never completed")
    }
  }

  /// Runs every scheduled block, including any a block schedules, in order.
  func drain() async {
    while !queue.isEmpty {
      await runBounded(queue.removeFirst())
    }
  }
}

@MainActor
@Suite("LaunchOfferDriver (#3252)", .tags(.productOutcome))
struct LaunchOfferDriverTests {

  private static let card = RelocationFailurePresentation.nothingMoved(.diskFull)

  @Test("The offer is scheduled once, however many times did-finish launching is reported")
  func scheduledOnce() async {
    let rig = DriverRig(outcome: .continueNormally(failure: nil))
    rig.driver.didFinishLaunching()
    rig.driver.didFinishLaunching()
    #expect(rig.queue.count == 1)
    #expect(rig.log.events.isEmpty)
    await rig.drain()
    #expect(rig.log.count("preflight") == 1)
  }

  @Test("A failure starts the app first and shows the card afterwards, on a later turn")
  func failureStartsTheAppBeforeTheCard() async {
    let rig = DriverRig(outcome: .continueNormally(failure: Self.card))
    rig.sequencer.applicationWillFinishLaunching()
    rig.sequencer.applicationDidFinishLaunching()
    rig.driver.didFinishLaunching()
    await rig.runBounded(rig.queue.removeFirst())
    // The app has started and the card is only queued for a later turn.
    #expect(
      rig.log.events == [
        "prepare observability", "preflight", "construction requested", "target constructed",
        "will", "did",
      ])
    #expect(rig.queue.count == 1)
    await rig.drain()
    #expect(rig.log.events.last == "card diskFull")
    #expect(rig.log.count("card diskFull") == 1)
  }

  @Test("Not Now starts the app and queues no card")
  func notNowStartsWithoutACard() async {
    let rig = DriverRig(outcome: .continueNormally(failure: nil))
    rig.driver.didFinishLaunching()
    await rig.drain()
    #expect(rig.sequencer.phase == .started)
    #expect(rig.log.events.contains { $0.hasPrefix("card") } == false)
    #expect(rig.queue.isEmpty)
  }

  @Test("A hand-off starts nothing and shows nothing")
  func handOffStartsNothing() async {
    let rig = DriverRig(outcome: .handedOff)
    rig.driver.didFinishLaunching()
    await rig.drain()
    #expect(rig.sequencer.phase == .terminal)
    #expect(rig.log.events == ["prepare observability", "preflight"])
  }

  @Test("Termination before the offer's turn starts no offer and builds nothing")
  func terminatedBeforeTheTurn() async {
    let rig = DriverRig(outcome: .continueNormally(failure: Self.card))
    rig.driver.didFinishLaunching()
    rig.sequencer.applicationWillTerminate()
    await rig.drain()
    #expect(rig.log.events.isEmpty)
    #expect(rig.preflightStates.isEmpty)
  }

  @Test("A late completion after termination neither builds the app nor shows the card")
  func terminatedDuringThePreflight() async {
    let rig = DriverRig(outcome: .continueNormally(failure: Self.card))
    rig.onPreflight = { [unowned rig] in rig.sequencer.applicationWillTerminate() }
    rig.driver.didFinishLaunching()
    await rig.drain()
    #expect(rig.sequencer.phase == .terminal)
    #expect(rig.log.events == ["prepare observability", "preflight"])
    #expect(rig.queue.isEmpty)
  }

  @Test("A card queued before termination is dropped when its turn comes")
  func terminatedBetweenQueueAndCard() async {
    let rig = DriverRig(outcome: .continueNormally(failure: Self.card))
    rig.sequencer.applicationWillFinishLaunching()
    rig.sequencer.applicationDidFinishLaunching()
    rig.driver.didFinishLaunching()
    await rig.runBounded(rig.queue.removeFirst())
    // The app started and the card is queued for a later turn.
    #expect(rig.sequencer.phase == .started)
    #expect(rig.queue.count == 1)
    rig.sequencer.applicationWillTerminate()
    await rig.drain()
    #expect(rig.sequencer.phase == .terminal)
    #expect(rig.log.events.contains { $0.hasPrefix("card") } == false)
    #expect(rig.queue.isEmpty)
  }

  @Test("A repeated completion starts the app once and shows the card once")
  func repeatedCompletion() async {
    let rig = DriverRig(outcome: .continueNormally(failure: Self.card))
    rig.driver.complete(.continueNormally(failure: Self.card))
    rig.driver.complete(.continueNormally(failure: Self.card))
    rig.driver.complete(.handedOff)
    await rig.drain()
    #expect(rig.log.count("construction requested") == 1)
    #expect(rig.log.count("card diskFull") == 1)
    #expect(rig.sequencer.phase == .started)
  }

  @Test("A completion after a hand-off is ignored")
  func completionAfterHandOff() async {
    let rig = DriverRig(outcome: .handedOff)
    rig.driver.complete(.handedOff)
    rig.driver.complete(.continueNormally(failure: Self.card))
    await rig.drain()
    #expect(rig.log.events.isEmpty)
    #expect(rig.sequencer.phase == .terminal)
  }

  @Test(
    "The blocking state reaches the pre-flight unchanged",
    arguments: [ApplicationLocationState.translocated, .readOnlyVolume])
  func stateIsPassedThrough(state: ApplicationLocationState) async {
    let rig = DriverRig(outcome: .continueNormally(failure: nil), state: state)
    rig.driver.didFinishLaunching()
    await rig.drain()
    #expect(rig.preflightStates == [state])
  }

  // MARK: The plan: who gets a driver at all

  @Test("A healthy launch has no plan to offer and gets no driver")
  func healthyLaunchGetsNoDriver() {
    let h = ApplicationRelocationCoordinatorTests.makeHarness(
      bundleURL: ApplicationRelocationCoordinatorTests.healthyURL)
    let plan = RelocationLaunchPlan(coordinator: h.coordinator)
    let log = SequencerEventLog()
    #expect(plan.offersFirst == false)
    #expect(
      LaunchOfferDriver(sequencer: makeSequencer(startImmediately: true, log: log), plan: plan)
        == nil)
  }

  @Test("A bad location whose offer is due gets a driver; one inside its cooldown does not")
  func badLocationGetsADriverOnlyWhenDue() {
    let due = ApplicationRelocationCoordinatorTests.makeHarness(
      bundleURL: ApplicationRelocationCoordinatorTests.translocatedURL)
    let duePlan = RelocationLaunchPlan(coordinator: due.coordinator)
    #expect(duePlan.offersFirst == true)
    #expect(duePlan.blockingState == .translocated)
    let log = SequencerEventLog()
    #expect(
      LaunchOfferDriver(sequencer: makeSequencer(startImmediately: false, log: log), plan: duePlan)
        != nil)

    let suppression = ApplicationRelocationCoordinatorTests.FakeSuppression()
    suppression.stored = (Date(timeIntervalSince1970: 1_000_000 - 60), "2.3.0")
    let declined = ApplicationRelocationCoordinatorTests.makeHarness(
      bundleURL: ApplicationRelocationCoordinatorTests.translocatedURL, suppression: suppression)
    let declinedPlan = RelocationLaunchPlan(coordinator: declined.coordinator)
    #expect(declinedPlan.offersFirst == false)
    #expect(
      LaunchOfferDriver(
        sequencer: makeSequencer(startImmediately: true, log: log), plan: declinedPlan) == nil)
  }

  @Test("A relaunched child is never offered the move")
  func childGetsNoDriver() {
    let h = ApplicationRelocationCoordinatorTests.makeHarness(
      bundleURL: ApplicationRelocationCoordinatorTests.translocatedURL,
      relaunchAttemptID: "attempt-1")
    #expect(RelocationLaunchPlan(coordinator: h.coordinator).offersFirst == false)
  }
}

// MARK: - Early observability for an offer-first launch (T6, ordering at the wiring site)

@MainActor
@Suite("Early observability for an offer-first launch (#3252)", .tags(.productOutcome))
struct LaunchObservabilityTests {

  @Test("Migration runs first, then the stored switches are read, then initialize gets them")
  func migrationThenReadThenInitialize() throws {
    let suite = try #require(TestDefaults.suite("ew-3252-early-\(UUID().uuidString)"))
    suite.set(false, forKey: "shareUsageMetrics")
    suite.set(true, forKey: "sendCrashReports")
    let log = SequencerEventLog()
    LaunchObservability.initializeForOffer(
      migrate: { log.add("migrate") },
      readSwitches: {
        log.add("read")
        return SettingsManager.storedTelemetrySwitches(defaults: suite)
      },
      initialize: { usage, crash in log.add("initialize usage=\(usage) crash=\(crash)") })
    #expect(log.events == ["migrate", "read", "initialize usage=false crash=true"])
  }

  @Test(
    "Every stored combination reaches initialize unchanged",
    arguments: [(true, true), (true, false), (false, true), (false, false)])
  func everyCombinationReachesInitialize(usage: Bool, crash: Bool) throws {
    let suite = try #require(TestDefaults.suite("ew-3252-early-\(UUID().uuidString)"))
    suite.set(usage, forKey: "shareUsageMetrics")
    suite.set(crash, forKey: "sendCrashReports")
    let log = SequencerEventLog()
    LaunchObservability.initializeForOffer(
      migrate: {},
      readSwitches: { SettingsManager.storedTelemetrySwitches(defaults: suite) },
      initialize: { log.add("usage=\($0) crash=\($1)") })
    #expect(log.events == ["usage=\(usage) crash=\(crash)"])
  }

  @Test("With nothing stored, initialize gets the shipped defaults, ON and ON")
  func absentSwitchesInitializeOn() throws {
    let suite = try #require(TestDefaults.suite("ew-3252-early-\(UUID().uuidString)"))
    let log = SequencerEventLog()
    LaunchObservability.initializeForOffer(
      migrate: {},
      readSwitches: { SettingsManager.storedTelemetrySwitches(defaults: suite) },
      initialize: { log.add("usage=\($0) crash=\($1)") })
    #expect(log.events == ["usage=true crash=true"])
  }
}
