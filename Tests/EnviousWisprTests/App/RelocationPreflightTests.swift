import Foundation
import Testing

@testable import EnviousWisprAppKit

// #3252, plan 3.4 / T2, T3, T9 (the coordinator side). The production `runPreflight`, the real
// `HandoffAuthority` and the real watchdog are exercised; only the side-effecting seams are fakes,
// and the destination is a fake path that nothing ever touches. Stages are parked on gates so a
// late result can be released after the watchdog has expired. No clock waits and no yield budgets:
// every wait is a signal the fake or the subject sends. Every observation of such a signal or of
// a task's completion is bounded by a fail-fast deadline (a pure backstop that never feeds the
// subject), so a regression that stops the signal records a named failure instead of hanging.

/// Resumes its continuation at most once, from whichever of two tasks gets there first.
@MainActor
private final class PreflightOnce<Value: Sendable> {
  private var continuation: CheckedContinuation<Value, Never>?
  init(_ continuation: CheckedContinuation<Value, Never>) { self.continuation = continuation }
  func resume(_ value: Value) {
    continuation?.resume(returning: value)
    continuation = nil
  }
}

/// A task's value, or nil if it has not finished within `deadline`. The deadline task does not
/// wait for the observed task, and the observed task is never cancelled.
@MainActor
func preflightBoundedValue<Value: Sendable>(
  of task: Task<Value, Never>, deadline: Duration = .seconds(5)
) async -> Value? {
  await withCheckedContinuation { (continuation: CheckedContinuation<Value?, Never>) in
    let once = PreflightOnce<Value?>(continuation)
    Task { @MainActor in once.resume(await task.value) }
    Task { @MainActor in
      try? await Task.sleep(for: deadline)
      once.resume(nil)
    }
  }
}

/// A flag that waiters can observe with a deadline. `wait` returns false if it never fires.
actor PreflightSignal {
  private var fired = false
  private var nextID = 0
  private var waiters: [Int: CheckedContinuation<Bool, Never>] = [:]

  func fire() {
    fired = true
    let pending = waiters
    waiters = [:]
    pending.values.forEach { $0.resume(returning: true) }
  }

  func wait(deadline: Duration = .seconds(5)) async -> Bool {
    if fired { return true }
    return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
      let id = nextID
      nextID += 1
      waiters[id] = continuation
      Task { [weak self] in
        try? await Task.sleep(for: deadline)
        await self?.expire(id)
      }
    }
  }

  private func expire(_ id: Int) {
    waiters.removeValue(forKey: id)?.resume(returning: false)
  }
}

/// A one-shot rendezvous a fake parks on until the test releases it.
actor PreflightGate {
  private let enteredSignal = PreflightSignal()
  private var released = false
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  func park() async {
    await enteredSignal.fire()
    if released { return }
    await withCheckedContinuation { releaseWaiters.append($0) }
  }

  /// False if no caller parked within `deadline`.
  func waitUntilEntered(deadline: Duration = .seconds(5)) async -> Bool {
    await enteredSignal.wait(deadline: deadline)
  }

  func release() {
    released = true
    releaseWaiters.forEach { $0.resume() }
    releaseWaiters = []
  }
}

/// The watchdog's wait, fired by hand. Cancelling the waiting task ends it without firing.
actor PreflightWatchdogClock {
  private(set) var requested: [TimeInterval] = []
  private let armedSignal = PreflightSignal()
  private var parked: [CheckedContinuation<Void, Error>] = []
  private var fired = false

  func parkUntilFired(_ seconds: TimeInterval) async throws {
    requested.append(seconds)
    await armedSignal.fire()
    if fired { return }
    try Task.checkCancellation()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { parked.append($0) }
    } onCancel: {
      Task { await self.cancelParked() }
    }
  }

  func fire() {
    fired = true
    parked.forEach { $0.resume() }
    parked = []
  }

  /// False if the watchdog never asked to sleep within `deadline`.
  func waitUntilArmed(deadline: Duration = .seconds(5)) async -> Bool {
    await armedSignal.wait(deadline: deadline)
  }

  private func cancelParked() {
    parked.forEach { $0.resume(throwing: CancellationError()) }
    parked = []
  }
}

final class StageMover: ApplicationMoving, @unchecked Sendable {
  var result: Result<InstallResolution, RelocationFailure>
  let gate: PreflightGate?
  private(set) var calls = 0
  init(_ result: Result<InstallResolution, RelocationFailure>, gate: PreflightGate? = nil) {
    self.result = result
    self.gate = gate
  }
  func install(
    source: URL, destination: URL, expectedBundleIdentifier: String, currentVersion: String
  ) async -> Result<InstallResolution, RelocationFailure> {
    calls += 1
    if let gate { await gate.park() }
    return result
  }
}

final class StageRelauncher: RelocationRelaunching, @unchecked Sendable {
  var relaunchResult = true
  var activateResult = true
  let relaunchGate: PreflightGate?
  let activateGate: PreflightGate?
  private(set) var relaunchCalls = 0
  private(set) var activateCalls = 0
  init(relaunchGate: PreflightGate? = nil, activateGate: PreflightGate? = nil) {
    self.relaunchGate = relaunchGate
    self.activateGate = activateGate
  }
  func relaunch(
    _ installedURL: URL, attemptID: String, reason: String, destinationScope: String,
    expectedBundleVersion: String
  ) async -> Bool {
    relaunchCalls += 1
    if let relaunchGate { await relaunchGate.park() }
    return relaunchResult
  }
  func activateRunning(_ url: URL) async -> Bool {
    activateCalls += 1
    if let activateGate { await activateGate.park() }
    return activateResult
  }
}

final class StageHandshake: RelocationHandshaking, @unchecked Sendable {
  var outcome: RelocationAckOutcome = .confirmed
  let gate: PreflightGate?
  private(set) var awaitCalls = 0
  init(gate: PreflightGate? = nil) { self.gate = gate }
  func awaitAck(
    attemptID: String, destination: URL, expectedBundleVersion: String, timeout: TimeInterval
  ) async -> RelocationAckOutcome {
    awaitCalls += 1
    if let gate { await gate.park() }
    return outcome
  }
  func writeAck(
    attemptID: String, resolvedPath: String, healthy: Bool, stateLabel: String?,
    bundleVersion: String?
  ) -> Bool { true }
}

@MainActor
final class PreflightRecordingPresenter: RelocationPresenting {
  var choice: RelocationChoice = .move
  let gate: PreflightGate?
  private(set) var progressShown = 0
  private(set) var progressDismissed = 0
  private(set) var presentations: [RelocationFailurePresentation] = []
  init(gate: PreflightGate? = nil) { self.gate = gate }
  func present() async -> RelocationChoice {
    if let gate { await gate.park() }
    return choice
  }
  func showProgress() { progressShown += 1 }
  func dismissProgress() { progressDismissed += 1 }
  func showFailure(_ presentation: RelocationFailurePresentation) {
    presentations.append(presentation)
  }
}

/// Everything the forbidden-effect assertions compare before and after a late result.
struct PreflightEffects: Equatable {
  var moverCalls = 0
  var relaunchCalls = 0
  var activateCalls = 0
  var awaitCalls = 0
  var terminates = 0
  var flushes = 0
  var progressShown = 0
  var progressDismissed = 0
  var failureCards = 0
  var offered = 0
  var accepted = 0
  var declined = 0
  var failed = 0
  var relaunched = 0
  var completed = 0
}

@MainActor
final class PreflightRig {
  static let destinationURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    .appendingPathComponent("ew-3252-fake-destination/EnviousWispr.app")

  let mover: StageMover
  let relauncher: StageRelauncher
  let handshake: StageHandshake
  let presenter: PreflightRecordingPresenter
  let telemetry = ApplicationRelocationCoordinatorTests.FakeTelemetry()
  let suppression = ApplicationRelocationCoordinatorTests.FakeSuppression()
  let clock = PreflightWatchdogClock()
  private(set) var coordinator: ApplicationRelocationCoordinator!
  private(set) var terminates = 0
  private(set) var flushes = 0
  /// Whether the fake destination process is still running when the hand-off checks.
  var destinationRunning = true
  private(set) var runningChecks: [(bundleIdentifier: String, url: URL)] = []
  /// What had already happened at the instant `terminate()` was called.
  private(set) var atTerminate:
    (relaunched: Int, completed: Int, flushes: Int, authority: HandoffAuthority.State?)?

  static let watchdogSeconds: TimeInterval = 7

  init(
    mover: StageMover, relauncher: StageRelauncher = StageRelauncher(),
    handshake: StageHandshake = StageHandshake(),
    presenter: PreflightRecordingPresenter = PreflightRecordingPresenter()
  ) {
    self.mover = mover
    self.relauncher = relauncher
    self.handshake = handshake
    self.presenter = presenter
    let clock = self.clock
    coordinator = ApplicationRelocationCoordinator(
      env: RelocationEnvironment(
        bundleURL: ApplicationRelocationCoordinatorTests.translocatedURL,
        bundleIdentifier: "com.enviouswispr.app", currentVersion: "2.3.0",
        relaunchAttemptID: nil),
      detector: ApplicationLocationDetector(),
      suppression: suppression, presenter: presenter, mover: mover, relauncher: relauncher,
      handshake: handshake, telemetry: telemetry,
      now: { Date(timeIntervalSince1970: 1_000_000) },
      terminate: { [unowned self] in
        terminates += 1
        atTerminate = (
          telemetry.relaunchedEvents.count, telemetry.completedEvents.count, flushes,
          coordinator.preflightAuthority?.state
        )
      },
      flushTelemetry: { [unowned self] in flushes += 1 },
      makeAttemptID: { "attempt-3252" },
      chooseDestination: { _ in
        ApplicationRelocationCoordinator.Destination(
          url: PreflightRig.destinationURL, scope: "user_applications")
      },
      moveWatchdogSeconds: PreflightRig.watchdogSeconds,
      watchdogSleep: { try await clock.parkUntilFired($0) },
      destinationIsRunning: { [unowned self] identifier, url in
        runningChecks.append((identifier, url))
        return destinationRunning
      })
  }

  /// Runs the pre-flight with a deadline. nil means it never returned: the failure is recorded
  /// and the watchdog is fired so nothing stays parked.
  func run(state: ApplicationLocationState = .translocated) async -> PreflightOutcome? {
    let task = Task { @MainActor [self] in await coordinator.runPreflight(state: state) }
    let outcome = await preflightBoundedValue(of: task)
    if outcome == nil {
      Issue.record("runPreflight never completed")
      await clock.fire()
    }
    return outcome
  }

  /// Waits, with a deadline, for the subject's own worker task to finish reconciling.
  func settleWorker() async {
    guard let worker = coordinator.preflightWorker else {
      Issue.record("the pre-flight worker was never started")
      return
    }
    if await preflightBoundedValue(of: worker) == nil {
      Issue.record("the pre-flight worker never finished")
    }
  }

  var effects: PreflightEffects {
    PreflightEffects(
      moverCalls: mover.calls, relaunchCalls: relauncher.relaunchCalls,
      activateCalls: relauncher.activateCalls, awaitCalls: handshake.awaitCalls,
      terminates: terminates, flushes: flushes, progressShown: presenter.progressShown,
      progressDismissed: presenter.progressDismissed, failureCards: presenter.presentations.count,
      offered: telemetry.offeredEvents.count, accepted: telemetry.acceptedEvents.count,
      declined: telemetry.declinedEvents.count, failed: telemetry.failedEvents.count,
      relaunched: telemetry.relaunchedEvents.count, completed: telemetry.completedEvents.count)
  }

  static func installed() -> Result<InstallResolution, RelocationFailure> {
    .success(.installed(destinationURL, bundleVersion: "1.0"))
  }
  static func existingRunning() -> Result<InstallResolution, RelocationFailure> {
    .success(.existingRunning(destinationURL, bundleVersion: "1.0"))
  }
}

@MainActor
@Suite("Relocation pre-flight (#3252)", .tags(.productOutcome))
struct RelocationPreflightTests {

  // MARK: Admission and the two non-move exits

  @Test("Not Now records the decline, reports it once and starts nothing")
  func notNow() async {
    let rig = PreflightRig(mover: StageMover(PreflightRig.installed()))
    rig.presenter.choice = .notNow
    guard let outcome = await rig.run() else { return }
    #expect(outcome == .continueNormally(failure: nil))
    #expect(rig.suppression.stored?.version == "2.3.0")
    #expect(rig.suppression.stored?.at == Date(timeIntervalSince1970: 1_000_000))
    #expect(rig.telemetry.declinedEvents == ["translocated"])
    #expect(rig.effects.moverCalls == 0 && rig.effects.progressShown == 0)
    #expect(rig.effects.terminates == 0)
    #expect(rig.coordinator.preflightAuthority == nil)
  }

  @Test("A location that does not block updates returns at once with no side effects")
  func nonBlockingStateDoesNothing() async {
    let rig = PreflightRig(mover: StageMover(PreflightRig.installed()))
    guard let outcome = await rig.run(state: .healthy) else { return }
    #expect(outcome == .continueNormally(failure: nil))
    #expect(rig.effects == PreflightEffects())
  }

  @Test("A second call after the first finished returns the first outcome and does nothing")
  func secondCallReturnsTheFirstOutcome() async {
    let rig = PreflightRig(mover: StageMover(PreflightRig.installed()))
    #expect(await rig.run() == .handedOff)
    let before = rig.effects
    #expect(await rig.run() == .handedOff)
    #expect(rig.effects == before)
    #expect(rig.effects.offered == 1 && rig.effects.terminates == 1)
  }

  @Test("A second call after Not Now returns that outcome and opens no second offer")
  func secondCallAfterNotNow() async {
    let rig = PreflightRig(mover: StageMover(PreflightRig.installed()))
    rig.presenter.choice = .notNow
    _ = await rig.run()
    let before = rig.effects
    #expect(
      await rig.run() == .continueNormally(failure: nil))
    #expect(rig.effects == before)
    #expect(rig.effects.offered == 1)
  }

  @Test("A call while the first is in flight waits for it: one offer, one worker, same outcome")
  func reentrantCallJoinsTheFirstRun() async {
    let gate = PreflightGate()
    let rig = PreflightRig(mover: StageMover(PreflightRig.installed(), gate: gate))
    let first = Task { await rig.coordinator.runPreflight(state: .translocated) }
    guard await gate.waitUntilEntered() else {
      Issue.record("the mover never started")
      await gate.release()
      return
    }
    let second = Task { await rig.coordinator.runPreflight(state: .translocated) }
    await gate.release()
    #expect(await preflightBoundedValue(of: first) == .handedOff)
    #expect(await preflightBoundedValue(of: second) == .handedOff)
    #expect(rig.effects.moverCalls == 1 && rig.effects.accepted == 1)
    #expect(rig.effects.offered == 1 && rig.effects.terminates == 1)
  }

  // MARK: The bounded waits fail fast when no signal arrives

  @Test("Control: waiting for a stage nobody enters, or a task that never ends, times out")
  func boundedWaitsTimeOutWithoutASignal() async {
    let gate = PreflightGate()
    #expect(await gate.waitUntilEntered(deadline: .milliseconds(50)) == false)
    let rig = PreflightRig(mover: StageMover(PreflightRig.installed()))
    #expect(await rig.clock.waitUntilArmed(deadline: .milliseconds(50)) == false)
    let parked = PreflightGate()
    let neverEnds = Task<Int, Never> {
      await parked.park()
      return 1
    }
    #expect(await preflightBoundedValue(of: neverEnds, deadline: .milliseconds(50)) == nil)
    await parked.release()
    #expect(await preflightBoundedValue(of: neverEnds) == 1)
  }

  // MARK: The watchdog

  @Test("The watchdog arms when Move is accepted, not while the person reads the offer")
  func watchdogStartsAtMove() async {
    let presenterGate = PreflightGate()
    let rig = PreflightRig(
      mover: StageMover(PreflightRig.installed()), presenter: PreflightRecordingPresenter(gate: presenterGate))
    let run = Task { await rig.coordinator.runPreflight(state: .translocated) }
    guard await presenterGate.waitUntilEntered() else {
      Issue.record("the offer was never presented")
      await presenterGate.release()
      return
    }
    #expect(await rig.clock.requested.isEmpty)
    await presenterGate.release()
    guard await rig.clock.waitUntilArmed() else {
      Issue.record("the watchdog never armed after Move")
      await rig.clock.fire()
      return
    }
    #expect(await rig.clock.requested == [PreflightRig.watchdogSeconds])
    #expect(await preflightBoundedValue(of: run) == .handedOff)
  }

  @Test("The default watchdog is the 20 s placeholder, NOT calibrated (Chunk 4 owns it)")
  func defaultWatchdogIsTheNamedPlaceholder() {
    // A literal on purpose: this pins the placeholder's value, it does not calibrate anything.
    #expect(ApplicationRelocationCoordinator.provisionalMoveWatchdogSeconds == 20)
  }

  // MARK: Success commits before the parent terminates

  @Test("Relaunch route: a confirmed ack commits, reports once, flushes, then terminates")
  func relaunchRouteCommitsBeforeTerminate() async {
    let rig = PreflightRig(mover: StageMover(PreflightRig.installed()))
    guard let outcome = await rig.run() else { return }
    #expect(outcome == .handedOff)
    #expect(rig.coordinator.preflightAuthority?.state == .committed)
    #expect(rig.effects.terminates == 1)
    #expect(rig.atTerminate?.authority == .committed)
    #expect(rig.atTerminate?.relaunched == 1)
    #expect(rig.atTerminate?.flushes == 1)
    #expect(rig.effects.completed == 0)
    #expect(rig.effects.failed == 0 && rig.effects.progressDismissed == 0)
    #expect(rig.relauncher.relaunchCalls == 1 && rig.handshake.awaitCalls == 1)
    #expect(rig.runningChecks.map(\.bundleIdentifier) == ["com.enviouswispr.app"])
    #expect(rig.runningChecks.map(\.url) == [PreflightRig.destinationURL])
  }

  @Test("Activate route: success commits, reports relaunched and completed, then terminates")
  func activateRouteCommitsBeforeTerminate() async {
    let rig = PreflightRig(mover: StageMover(PreflightRig.existingRunning()))
    guard let outcome = await rig.run() else { return }
    #expect(outcome == .handedOff)
    #expect(rig.coordinator.preflightAuthority?.state == .committed)
    #expect(rig.effects.terminates == 1)
    #expect(rig.atTerminate?.authority == .committed)
    #expect(rig.atTerminate?.relaunched == 1)
    #expect(rig.atTerminate?.completed == 1)
    #expect(rig.atTerminate?.flushes == 1)
    #expect(rig.telemetry.completedEvents.first?.source == "existing_running_activation")
    #expect(rig.relauncher.relaunchCalls == 0 && rig.handshake.awaitCalls == 0)
    #expect(rig.runningChecks.map(\.url) == [PreflightRig.destinationURL])
  }

  @Test("After a hand-off, firing the watchdog changes nothing")
  func firingAfterHandOffIsInert() async {
    let rig = PreflightRig(mover: StageMover(PreflightRig.installed()))
    #expect(await rig.run() == .handedOff)
    let before = rig.effects
    await rig.clock.fire()
    await rig.settleWorker()
    #expect(rig.effects == before)
    #expect(rig.coordinator.preflightAuthority?.state == .committed)
  }

  // MARK: Every failure exit releases, returns the card and shows none (T2, T9)

  struct FailureRow: CustomTestStringConvertible, Sendable {
    let name: String
    let route: Route
    let ack: RelocationAckOutcome
    let relaunchOK: Bool
    let activateOK: Bool
    let moverFailure: RelocationFailure?
    let failure: RelocationFailure
    let installedNotConfirmed: Bool
    let installLabel: String
    var destinationRunning = true
    enum Route: Sendable { case relaunch, activate }
    var testDescription: String { name }
  }

  nonisolated static let failureRows: [FailureRow] = [
    FailureRow(
      name: "mover diskFull", route: .relaunch, ack: .confirmed, relaunchOK: true,
      activateOK: true, moverFailure: .diskFull, failure: .diskFull,
      installedNotConfirmed: false, installLabel: "unresolved"),
    FailureRow(
      name: "mover signatureInvalid", route: .relaunch, ack: .confirmed, relaunchOK: true,
      activateOK: true, moverFailure: .signatureInvalid, failure: .signatureInvalid,
      installedNotConfirmed: false, installLabel: "unresolved"),
    FailureRow(
      name: "mover stripFailedAtDestination", route: .relaunch, ack: .confirmed,
      relaunchOK: true, activateOK: true, moverFailure: .stripFailedAtDestination,
      failure: .stripFailedAtDestination, installedNotConfirmed: false,
      installLabel: "existing_usable"),
    FailureRow(
      name: "mover stripFailedAfterPlacement", route: .relaunch, ack: .confirmed,
      relaunchOK: true, activateOK: true, moverFailure: .stripFailedAfterPlacement,
      failure: .stripFailedAfterPlacement, installedNotConfirmed: false,
      installLabel: "installed"),
    FailureRow(
      name: "relaunch rejected", route: .relaunch, ack: .confirmed, relaunchOK: false,
      activateOK: true, moverFailure: nil, failure: .relaunchRejected,
      installedNotConfirmed: true, installLabel: "installed"),
    FailureRow(
      name: "ack timed out", route: .relaunch, ack: .timedOut, relaunchOK: true,
      activateOK: true, moverFailure: nil, failure: .ackTimeout, installedNotConfirmed: true,
      installLabel: "installed"),
    FailureRow(
      name: "ack malformed", route: .relaunch, ack: .malformed, relaunchOK: true,
      activateOK: true, moverFailure: nil, failure: .ackMalformed, installedNotConfirmed: true,
      installLabel: "installed"),
    FailureRow(
      name: "ack path mismatch", route: .relaunch, ack: .pathMismatch, relaunchOK: true,
      activateOK: true, moverFailure: nil, failure: .ackPathMismatch,
      installedNotConfirmed: true, installLabel: "installed"),
    FailureRow(
      name: "ack version mismatch", route: .relaunch, ack: .versionMismatch,
      relaunchOK: true, activateOK: true, moverFailure: nil, failure: .ackVersionMismatch,
      installedNotConfirmed: true, installLabel: "installed"),
    FailureRow(
      name: "ack unhealthy translocated", route: .relaunch,
      ack: .unhealthy(stateLabel: "translocated"), relaunchOK: true, activateOK: true,
      moverFailure: nil, failure: .ackUnhealthyTranslocated, installedNotConfirmed: false,
      installLabel: "installed"),
    FailureRow(
      name: "ack unhealthy other", route: .relaunch,
      ack: .unhealthy(stateLabel: "read_only_volume"), relaunchOK: true, activateOK: true,
      moverFailure: nil, failure: .ackUnhealthyOther, installedNotConfirmed: false,
      installLabel: "installed"),
    FailureRow(
      name: "activation failed", route: .activate, ack: .confirmed, relaunchOK: true,
      activateOK: false, moverFailure: nil, failure: .relaunchRejected,
      installedNotConfirmed: true, installLabel: "existing_running"),
    FailureRow(
      name: "relaunch route: destination exited after a healthy ack", route: .relaunch,
      ack: .confirmed, relaunchOK: true, activateOK: true, moverFailure: nil,
      failure: .relaunchRejected, installedNotConfirmed: true, installLabel: "installed",
      destinationRunning: false),
    FailureRow(
      name: "activate route: destination exited after activation", route: .activate,
      ack: .confirmed, relaunchOK: true, activateOK: true, moverFailure: nil,
      failure: .relaunchRejected, installedNotConfirmed: true, installLabel: "existing_running",
      destinationRunning: false),
  ]

  @Test(
    "Every failure exit releases, returns the right card and shows none itself",
    arguments: failureRows)
  func failureExits(row: FailureRow) async {
    let moverResult: Result<InstallResolution, RelocationFailure>
    if let failure = row.moverFailure {
      moverResult = .failure(failure)
    } else {
      moverResult = row.route == .activate ? PreflightRig.existingRunning() : PreflightRig.installed()
    }
    let relauncher = StageRelauncher()
    relauncher.relaunchResult = row.relaunchOK
    relauncher.activateResult = row.activateOK
    let handshake = StageHandshake()
    handshake.outcome = row.ack
    let rig = PreflightRig(mover: StageMover(moverResult), relauncher: relauncher, handshake: handshake)
    rig.destinationRunning = row.destinationRunning

    let run = Task { await rig.coordinator.runPreflight(state: .translocated) }
    guard let outcome = await preflightBoundedValue(of: run) else {
      Issue.record("runPreflight never returned for \(row.name)")
      await rig.clock.fire()
      return
    }

    let expectedCard: RelocationFailurePresentation =
      row.installedNotConfirmed
      ? .installedNotConfirmed(row.failure, destination: PreflightRig.destinationURL)
      : .nothingMoved(row.failure)
    #expect(outcome == .continueNormally(failure: expectedCard))
    // T9, coordinator boundary: the card is RETURNED, never shown by the coordinator, so the
    // caller can start normally first. (Production caller ordering is Chunk 2 / Chunk 4.)
    #expect(rig.presenter.presentations.isEmpty)
    #expect(rig.presenter.progressDismissed == 1)
    #expect(rig.telemetry.failedEvents.map(\.1) == [row.failure.rawValue])
    #expect(rig.telemetry.lastFailedInstallResolution == row.installLabel)
    #expect(rig.effects.terminates == 0)
    #expect(rig.effects.relaunched == 0 && rig.effects.completed == 0)
    #expect(rig.coordinator.preflightAuthority?.state == .released)
  }

  // MARK: Watchdog expiry with a stage in flight; the late result must be inert (T3)

  enum Stage: String, Sendable, CaseIterable { case install, activate, relaunch, ack }

  struct LateCase: CustomTestStringConvertible, Sendable {
    let stage: Stage
    let lateSuccess: Bool
    var testDescription: String {
      "\(stage.rawValue) late \(lateSuccess ? "success" : "failure")"
    }
  }

  nonisolated static let lateCases: [LateCase] = Stage.allCases.flatMap { stage in
    [true, false].map { LateCase(stage: stage, lateSuccess: $0) }
  }

  @Test(
    "Expiry returns without the worker; the late result then does nothing", arguments: lateCases)
  func lateResultIsInert(late: LateCase) async {
    let gate = PreflightGate()
    let rig: PreflightRig
    switch late.stage {
    case .install:
      rig = PreflightRig(mover: StageMover(PreflightRig.installed(), gate: gate))
    case .activate:
      rig = PreflightRig(
        mover: StageMover(PreflightRig.existingRunning()), relauncher: StageRelauncher(activateGate: gate))
    case .relaunch:
      rig = PreflightRig(
        mover: StageMover(PreflightRig.installed()), relauncher: StageRelauncher(relaunchGate: gate))
    case .ack:
      rig = PreflightRig(mover: StageMover(PreflightRig.installed()), handshake: StageHandshake(gate: gate))
    }

    let run = Task { await rig.coordinator.runPreflight(state: .translocated) }
    guard await gate.waitUntilEntered() else {
      Issue.record("the \(late.stage.rawValue) stage never started")
      await gate.release()
      await rig.clock.fire()
      return
    }
    await rig.clock.fire()
    // runPreflight returns while the worker is still parked: it never waits for it.
    guard let outcome = await preflightBoundedValue(of: run) else {
      Issue.record("runPreflight did not return after the watchdog fired (\(late.stage.rawValue))")
      await gate.release()
      return
    }
    #expect(outcome == .continueNormally(failure: .nothingMoved(.installTimedOut)))
    #expect(rig.coordinator.preflightAuthority?.state == .released)
    #expect(rig.telemetry.failedEvents.map(\.1) == ["installTimedOut"])
    #expect(rig.telemetry.lastFailedInstallResolution == "unresolved")
    #expect(rig.presenter.progressDismissed == 1)
    #expect(rig.presenter.presentations.isEmpty)
    let before = rig.effects

    // Complete the parked stage late, with success or failure, then wait for the SUBJECT's own
    // worker task to finish reconciling it.
    switch late.stage {
    case .install:
      rig.mover.result = late.lateSuccess ? PreflightRig.installed() : .failure(.diskFull)
    case .activate:
      rig.relauncher.activateResult = late.lateSuccess
    case .relaunch:
      rig.relauncher.relaunchResult = late.lateSuccess
    case .ack:
      rig.handshake.outcome = late.lateSuccess ? .confirmed : .unhealthy(stateLabel: nil)
    }
    await gate.release()
    await rig.settleWorker()

    // The complete forbidden-effect vector: no launch, activation, ack wait, flush, termination,
    // card, progress change, or second terminal event.
    #expect(rig.effects == before)
    #expect(rig.effects.terminates == 0 && rig.effects.flushes == 0)
    #expect(rig.effects.failed == 1)
    #expect(rig.coordinator.preflightAuthority?.state == .released)
    switch late.stage {
    case .install:
      #expect(rig.effects.relaunchCalls == 0 && rig.effects.activateCalls == 0)
    case .relaunch:
      #expect(rig.effects.awaitCalls == 0)
    case .activate, .ack:
      break
    }
  }

  @Test("A stage failure that wins the race is reported once; a later expiry adds nothing")
  func expiryAfterFailureAddsNothing() async {
    let rig = PreflightRig(mover: StageMover(.failure(.diskFull)))
    guard let outcome = await rig.run() else { return }
    #expect(outcome == .continueNormally(failure: .nothingMoved(.diskFull)))
    let before = rig.effects
    await rig.clock.fire()
    await rig.settleWorker()
    #expect(rig.effects == before)
    #expect(rig.effects.failed == 1)
    #expect(rig.coordinator.preflightAuthority?.state == .released)
  }
}
