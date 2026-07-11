import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #1451 — App Translocation recovery. Pure-policy + flow tests with fakes for
/// every side-effecting seam. The detector is exercised through crafted bundle
/// URLs (a `/AppTranslocation/` path segment forces `.translocated` before
/// `statfs`; a writable existing dir is `.healthy`).
@MainActor
@Suite("ApplicationRelocationCoordinator")
struct ApplicationRelocationCoordinatorTests {

  // MARK: Fakes

  final class FakeSuppression: RelocationSuppressionStore, @unchecked Sendable {
    var stored: (at: Date, version: String)?
    var clearCount = 0
    func lastDecline() -> (at: Date, version: String)? { stored }
    func recordDecline(at: Date, version: String) { stored = (at, version) }
    func clear() {
      clearCount += 1
      stored = nil
    }
  }

  @MainActor final class FakePresenter: RelocationPresenting {
    var choice: RelocationChoice = .move
    var progressShown = 0
    var progressDismissed = 0
    var failures: [RelocationFailure] = []
    func present() async -> RelocationChoice { choice }
    func showProgress() { progressShown += 1 }
    func dismissProgress() { progressDismissed += 1 }
    func showFailure(_ failure: RelocationFailure) { failures.append(failure) }
  }

  final class FakeMover: ApplicationMoving, @unchecked Sendable {
    var result: Result<InstallResolution, RelocationFailure>
    private(set) var calls = 0
    init(_ result: Result<InstallResolution, RelocationFailure>) { self.result = result }
    func install(
      source: URL, destination: URL, expectedBundleIdentifier: String, currentVersion: String
    ) async -> Result<InstallResolution, RelocationFailure> {
      calls += 1
      return result
    }
  }

  final class FakeRelauncher: RelocationRelaunching, @unchecked Sendable {
    var success = true
    var activateSuccess = true
    private(set) var lastAttemptID: String?
    private(set) var relaunchCalls = 0
    private(set) var activatedURL: URL?
    func relaunch(_ installedURL: URL, attemptID: String) async -> Bool {
      relaunchCalls += 1
      lastAttemptID = attemptID
      return success
    }
    func activateRunning(_ url: URL) async -> Bool {
      activatedURL = url
      return activateSuccess
    }
  }

  final class FakeHandshake: RelocationHandshaking, @unchecked Sendable {
    var ackHealthy = true
    private(set) var awaitCalls = 0
    private(set) var writes: [(attemptID: String, path: String, healthy: Bool)] = []
    func awaitAck(attemptID: String, destination: URL, timeout: TimeInterval) async -> Bool {
      awaitCalls += 1
      return ackHealthy
    }
    func writeAck(attemptID: String, resolvedPath: String, healthy: Bool) {
      writes.append((attemptID, resolvedPath, healthy))
    }
  }

  @MainActor final class FakeTelemetry: RelocationTelemetrySink {
    var offeredEvents: [(String, String)] = []
    var acceptedEvents: [(String, String)] = []
    var declinedEvents: [String] = []
    var failedEvents: [(String, String)] = []
    var relaunchedEvents: [(String, String, Bool)] = []
    func offered(reason: String, destinationScope: String) {
      offeredEvents.append((reason, destinationScope))
    }
    func accepted(reason: String, destinationScope: String) {
      acceptedEvents.append((reason, destinationScope))
    }
    func declined(reason: String) { declinedEvents.append(reason) }
    func failed(reason: String, failureClass: String) {
      failedEvents.append((reason, failureClass))
    }
    func relaunched(reason: String, destinationScope: String, relaunchConfirmed: Bool) {
      relaunchedEvents.append((reason, destinationScope, relaunchConfirmed))
    }
  }

  final class TerminateBox: @unchecked Sendable { var count = 0 }

  // MARK: Fixtures

  static let translocatedURL = URL(
    fileURLWithPath: "/private/var/folders/ab/AppTranslocation/XYZ/d/EnviousWispr.app")
  static var healthyURL: URL { URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true) }

  struct Harness {
    let coordinator: ApplicationRelocationCoordinator
    let suppression: FakeSuppression
    let presenter: FakePresenter
    let mover: FakeMover
    let relauncher: FakeRelauncher
    let handshake: FakeHandshake
    let telemetry: FakeTelemetry
    let terminate: TerminateBox
  }

  static func makeHarness(
    bundleURL: URL,
    version: String = "2.3.0",
    relaunchAttemptID: String? = nil,
    moverResult: Result<InstallResolution, RelocationFailure> = .success(
      .installed(URL(fileURLWithPath: "/Applications/EnviousWispr.app"))),
    now: Date = Date(timeIntervalSince1970: 1_000_000)
  ) -> Harness {
    let suppression = FakeSuppression()
    let presenter = FakePresenter()
    let mover = FakeMover(moverResult)
    let relauncher = FakeRelauncher()
    let handshake = FakeHandshake()
    let telemetry = FakeTelemetry()
    let terminate = TerminateBox()
    let coordinator = ApplicationRelocationCoordinator(
      env: RelocationEnvironment(
        bundleURL: bundleURL, bundleIdentifier: "com.enviouswispr.app",
        currentVersion: version, relaunchAttemptID: relaunchAttemptID),
      detector: ApplicationLocationDetector(),
      suppression: suppression,
      presenter: presenter,
      mover: mover,
      relauncher: relauncher,
      handshake: handshake,
      telemetry: telemetry,
      now: { now },
      terminate: { terminate.count += 1 },
      makeAttemptID: { "attempt-1" })
    return Harness(
      coordinator: coordinator, suppression: suppression, presenter: presenter, mover: mover,
      relauncher: relauncher, handshake: handshake, telemetry: telemetry, terminate: terminate)
  }

  // MARK: Detection

  @Test("detector: /AppTranslocation/ path segment is translocated")
  func detectTranslocated() {
    #expect(ApplicationLocationDetector().state(for: Self.translocatedURL) == .translocated)
  }

  @Test("detector: writable existing dir is healthy")
  func detectHealthy() {
    #expect(ApplicationLocationDetector().state(for: Self.healthyURL) == .healthy)
  }

  @Test("detector: non-existent path fails open, never blocking")
  func detectFailsOpen() {
    let missing = URL(fileURLWithPath: "/no/such/path/\(UUID().uuidString)/EnviousWispr.app")
    let state = ApplicationLocationDetector().state(for: missing)
    #expect(state == .detectionFailed)
    #expect(state.isUpdateBlocking == false)
  }

  // MARK: Destination

  @Test("destination: keeps app name and a bounded scope")
  func destinationScope() {
    let dest = ApplicationRelocationCoordinator.chooseDestination(appName: "EnviousWispr.app")
    #expect(dest.url.lastPathComponent == "EnviousWispr.app")
    #expect(["system_applications", "user_applications"].contains(dest.scope))
  }

  // MARK: Cadence

  @Test("cadence: never declined -> offer")
  func cadenceFresh() {
    let h = Self.makeHarness(bundleURL: Self.translocatedURL)
    #expect(h.coordinator.shouldOffer(now: Date(timeIntervalSince1970: 1_000_000)))
  }

  @Test("cadence: declined yesterday, same version -> suppress")
  func cadenceRecentDecline() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let h = Self.makeHarness(bundleURL: Self.translocatedURL, version: "2.3.0", now: now)
    h.suppression.stored = (at: now.addingTimeInterval(-24 * 60 * 60), version: "2.3.0")
    #expect(h.coordinator.shouldOffer(now: now) == false)
  }

  @Test("cadence: declined 8 days ago -> offer again")
  func cadenceStaleDecline() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let h = Self.makeHarness(bundleURL: Self.translocatedURL, version: "2.3.0", now: now)
    h.suppression.stored = (at: now.addingTimeInterval(-8 * 24 * 60 * 60), version: "2.3.0")
    #expect(h.coordinator.shouldOffer(now: now))
  }

  @Test("cadence: version changed -> offer even within 7 days")
  func cadenceVersionChanged() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let h = Self.makeHarness(bundleURL: Self.translocatedURL, version: "2.4.0", now: now)
    h.suppression.stored = (at: now.addingTimeInterval(-60 * 60), version: "2.3.0")
    #expect(h.coordinator.shouldOffer(now: now))
  }

  // MARK: Healthy launch

  @Test("healthy launch: no prompt, clears stale decline, no telemetry")
  func healthyLaunchClears() async {
    let h = Self.makeHarness(bundleURL: Self.healthyURL)
    h.suppression.stored = (at: Date(timeIntervalSince1970: 1), version: "old")
    h.coordinator.evaluateAndOfferIfNeeded()
    await h.coordinator.pendingWork?.value
    #expect(h.suppression.clearCount == 1)
    #expect(h.telemetry.offeredEvents.isEmpty)
    #expect(h.presenter.progressShown == 0)
  }

  // MARK: Relaunched-child ack path (A2)

  @Test("relaunch child: healthy destination writes healthy ack, never prompts")
  func childAckHealthy() async {
    let h = Self.makeHarness(bundleURL: Self.healthyURL, relaunchAttemptID: "attempt-1")
    h.coordinator.evaluateAndOfferIfNeeded()
    await h.coordinator.pendingWork?.value
    #expect(h.handshake.writes.count == 1)
    #expect(h.handshake.writes.first?.healthy == true)
    #expect(h.telemetry.offeredEvents.isEmpty)  // no prompt on the child path
    #expect(h.presenter.progressShown == 0)
  }

  @Test("relaunch child: still-blocked destination writes UNhealthy ack (A2 no masking)")
  func childAckStillBad() async {
    let h = Self.makeHarness(bundleURL: Self.translocatedURL, relaunchAttemptID: "attempt-1")
    h.coordinator.evaluateAndOfferIfNeeded()
    await h.coordinator.pendingWork?.value
    #expect(h.handshake.writes.count == 1)
    #expect(h.handshake.writes.first?.healthy == false)
  }

  // MARK: Decline

  @Test("Not Now: records decline + declined telemetry, no move")
  func declineFlow() async {
    let h = Self.makeHarness(bundleURL: Self.translocatedURL)
    h.presenter.choice = .notNow
    h.coordinator.evaluateAndOfferIfNeeded()
    await h.coordinator.pendingWork?.value
    #expect(h.telemetry.offeredEvents.count == 1)
    #expect(h.telemetry.declinedEvents == ["translocated"])
    #expect(h.suppression.stored?.version == "2.3.0")
    #expect(h.mover.calls == 0)
    #expect(h.terminate.count == 0)
  }

  // MARK: Move success + handshake (A1)

  @Test("Move accepted -> install -> ack healthy -> relaunched telemetry + terminate")
  func moveSuccessConfirmed() async {
    let h = Self.makeHarness(bundleURL: Self.translocatedURL)
    h.presenter.choice = .move
    h.handshake.ackHealthy = true
    h.coordinator.evaluateAndOfferIfNeeded()
    await h.coordinator.pendingWork?.value
    #expect(h.telemetry.acceptedEvents.count == 1)
    #expect(h.mover.calls == 1)
    #expect(h.relauncher.lastAttemptID == "attempt-1")
    #expect(h.telemetry.relaunchedEvents.count == 1)
    #expect(h.telemetry.relaunchedEvents.first?.2 == true)  // relaunch_confirmed
    #expect(h.terminate.count == 1)
    #expect(h.presenter.failures.isEmpty)
  }

  // MARK: Handshake failure keeps the original alive (A1)

  @Test("ack unconfirmed -> original NEVER terminates, reports relaunchUnconfirmed")
  func moveAckTimeout() async {
    let h = Self.makeHarness(bundleURL: Self.translocatedURL)
    h.handshake.ackHealthy = false
    h.coordinator.evaluateAndOfferIfNeeded()
    await h.coordinator.pendingWork?.value
    #expect(h.terminate.count == 0)  // the only known-good copy stays alive
    #expect(h.telemetry.relaunchedEvents.isEmpty)
    #expect(h.telemetry.failedEvents.map(\.1) == ["relaunchUnconfirmed"])
    #expect(h.presenter.failures == [.relaunchUnconfirmed])
  }

  @Test("relaunch rejected -> failure, no terminate")
  func relaunchRejected() async {
    let h = Self.makeHarness(bundleURL: Self.translocatedURL)
    h.relauncher.success = false
    h.coordinator.evaluateAndOfferIfNeeded()
    await h.coordinator.pendingWork?.value
    #expect(h.terminate.count == 0)
    #expect(h.telemetry.failedEvents.map(\.1) == ["relaunchRejected"])
    #expect(h.presenter.failures == [.relaunchRejected])
  }

  // MARK: Move failure

  @Test("mover failure -> showFailure, dismiss progress, no terminate")
  func moveFailure() async {
    let h = Self.makeHarness(
      bundleURL: Self.translocatedURL, moverResult: .failure(.diskFull))
    h.coordinator.evaluateAndOfferIfNeeded()
    await h.coordinator.pendingWork?.value
    #expect(h.terminate.count == 0)
    #expect(h.telemetry.failedEvents.map(\.1) == ["diskFull"])
    #expect(h.presenter.failures == [.diskFull])
    #expect(h.presenter.progressDismissed >= 1)
    #expect(h.telemetry.relaunchedEvents.isEmpty)
  }

  // MARK: Existing-destination conflict matrix (Codex r2 P1 regression guard)

  @Test("existing-destination: different bundle id -> conflict, never touched")
  func decideDifferentIdentity() {
    let d = FileManagerApplicationMover.decideExistingDestination(
      existingBundleIdentifier: "com.someone.else",
      expectedBundleIdentifier: "com.enviouswispr.app",
      existingVersion: "9.9.9", currentVersion: "2.3.0", isRunning: false, signatureValid: true)
    #expect(d == .conflict)
  }

  @Test("existing-destination: newer verified, NOT running -> open fresh (no downgrade)")
  func decideNewerVerified() {
    let d = FileManagerApplicationMover.decideExistingDestination(
      existingBundleIdentifier: "com.enviouswispr.app",
      expectedBundleIdentifier: "com.enviouswispr.app",
      existingVersion: "2.4.0", currentVersion: "2.3.0", isRunning: false, signatureValid: true)
    #expect(d == .openExisting)
  }

  @Test(
    "existing-destination: newer verified + ALREADY running -> activate, never duplicate (cloud #1490)"
  )
  func decideNewerRunning() {
    let d = FileManagerApplicationMover.decideExistingDestination(
      existingBundleIdentifier: "com.enviouswispr.app",
      expectedBundleIdentifier: "com.enviouswispr.app",
      existingVersion: "2.4.0", currentVersion: "2.3.0", isRunning: true, signatureValid: true)
    #expect(d == .activateRunning)
  }

  @Test("existing-destination: equal version verified -> open it")
  func decideEqualVerified() {
    let d = FileManagerApplicationMover.decideExistingDestination(
      existingBundleIdentifier: "com.enviouswispr.app",
      expectedBundleIdentifier: "com.enviouswispr.app",
      existingVersion: "2.3.0", currentVersion: "2.3.0", isRunning: false, signatureValid: true)
    #expect(d == .openExisting)
  }

  @Test("existing-destination: same-or-newer but BAD signature -> conflict (never launch)")
  func decideNewerBadSignature() {
    let d = FileManagerApplicationMover.decideExistingDestination(
      existingBundleIdentifier: "com.enviouswispr.app",
      expectedBundleIdentifier: "com.enviouswispr.app",
      existingVersion: "2.5.0", currentVersion: "2.3.0", isRunning: false, signatureValid: false)
    #expect(d == .conflict)
  }

  @Test("existing-destination: OLDER + running -> refuse, do NOT downgrade (Codex r2 P1)")
  func decideOlderRunning() {
    let d = FileManagerApplicationMover.decideExistingDestination(
      existingBundleIdentifier: "com.enviouswispr.app",
      expectedBundleIdentifier: "com.enviouswispr.app",
      existingVersion: "2.2.0", currentVersion: "2.3.0", isRunning: true, signatureValid: true)
    #expect(d == .refuseRunningOlder)
  }

  @Test("existing-destination: OLDER + not running + verified -> replace")
  func decideOlderNotRunning() {
    let d = FileManagerApplicationMover.decideExistingDestination(
      existingBundleIdentifier: "com.enviouswispr.app",
      expectedBundleIdentifier: "com.enviouswispr.app",
      existingVersion: "2.2.0", currentVersion: "2.3.0", isRunning: false, signatureValid: true)
    #expect(d == .replace)
  }

  @Test(
    "existing-destination: OLDER + not running + BAD signature -> conflict, never overwrite (Codex r3 P2)"
  )
  func decideOlderBadSignature() {
    let d = FileManagerApplicationMover.decideExistingDestination(
      existingBundleIdentifier: "com.enviouswispr.app",
      expectedBundleIdentifier: "com.enviouswispr.app",
      existingVersion: "2.2.0", currentVersion: "2.3.0", isRunning: false, signatureValid: false)
    #expect(d == .conflict)
  }

  // MARK: existingUsable still handshakes (never terminate blind)

  @Test("existingUsable: still relaunches + requires ack before terminate")
  func existingUsableHandshakes() async {
    let dest = URL(fileURLWithPath: "/Applications/EnviousWispr.app")
    let h = Self.makeHarness(
      bundleURL: Self.translocatedURL, moverResult: .success(.existingUsable(dest)))
    h.handshake.ackHealthy = true
    h.coordinator.evaluateAndOfferIfNeeded()
    await h.coordinator.pendingWork?.value
    #expect(h.relauncher.lastAttemptID == "attempt-1")
    #expect(h.terminate.count == 1)
  }

  // MARK: existingRunning activates the live copy, never duplicates (cloud #1490)

  @Test(
    "existingRunning: activates the running copy, no fresh launch, no handshake, then terminates")
  func existingRunningActivates() async {
    let dest = URL(fileURLWithPath: "/Applications/EnviousWispr.app")
    let h = Self.makeHarness(
      bundleURL: Self.translocatedURL, moverResult: .success(.existingRunning(dest)))
    h.coordinator.evaluateAndOfferIfNeeded()
    await h.coordinator.pendingWork?.value
    #expect(h.relauncher.activatedURL == dest)  // brought the live copy to front
    #expect(h.relauncher.relaunchCalls == 0)  // NO duplicate instance spawned
    #expect(h.handshake.awaitCalls == 0)  // no handshake needed for an already-live copy
    #expect(h.telemetry.relaunchedEvents.first?.2 == true)
    #expect(h.terminate.count == 1)  // this translocated duplicate quits
  }

  @Test("existingRunning: activate failure keeps the original alive")
  func existingRunningActivateFailure() async {
    let dest = URL(fileURLWithPath: "/Applications/EnviousWispr.app")
    let h = Self.makeHarness(
      bundleURL: Self.translocatedURL, moverResult: .success(.existingRunning(dest)))
    h.relauncher.activateSuccess = false
    h.coordinator.evaluateAndOfferIfNeeded()
    await h.coordinator.pendingWork?.value
    #expect(h.terminate.count == 0)
    #expect(h.telemetry.failedEvents.map(\.1) == ["relaunchRejected"])
  }
}
