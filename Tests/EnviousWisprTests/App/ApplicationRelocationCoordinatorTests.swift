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
    var presentations: [RelocationFailurePresentation] = []
    /// Convenience for the many existing assertions that only care about class.
    var failures: [RelocationFailure] { presentations.map(\.failure) }
    func present() async -> RelocationChoice { choice }
    func showProgress() { progressShown += 1 }
    func dismissProgress() { progressDismissed += 1 }
    func showFailure(_ presentation: RelocationFailurePresentation) {
      presentations.append(presentation)
    }
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
    private(set) var lastReason: String?
    private(set) var lastDestinationScope: String?
    private(set) var lastExpectedVersion: String?
    func relaunch(
      _ installedURL: URL, attemptID: String, reason: String, destinationScope: String,
      expectedBundleVersion: String
    ) async -> Bool {
      relaunchCalls += 1
      lastAttemptID = attemptID
      lastReason = reason
      lastDestinationScope = destinationScope
      lastExpectedVersion = expectedBundleVersion
      return success
    }
    func activateRunning(_ url: URL) async -> Bool {
      activatedURL = url
      return activateSuccess
    }
  }

  final class FakeHandshake: RelocationHandshaking, @unchecked Sendable {
    /// Existing tests set this; `true` means confirmed, `false` means the
    /// generic unhealthy-other outcome. New tests set `outcome` directly.
    var ackHealthy = true {
      didSet { outcome = ackHealthy ? .confirmed : .unhealthy(stateLabel: "read_only_volume") }
    }
    var outcome: RelocationAckOutcome = .confirmed
    private(set) var awaitCalls = 0
    private(set) var lastExpectedVersion: String?
    private(set) var writes:
      [(attemptID: String, path: String, healthy: Bool, stateLabel: String?, version: String?)] = []
    func awaitAck(
      attemptID: String, destination: URL, expectedBundleVersion: String, timeout: TimeInterval
    ) async -> RelocationAckOutcome {
      awaitCalls += 1
      lastExpectedVersion = expectedBundleVersion
      return outcome
    }
    func writeAck(
      attemptID: String, resolvedPath: String, healthy: Bool, stateLabel: String?,
      bundleVersion: String?
    ) {
      writes.append((attemptID, resolvedPath, healthy, stateLabel, bundleVersion))
    }
  }

  @MainActor final class FakeTelemetry: RelocationTelemetrySink {
    var offeredEvents: [(String, String)] = []
    var acceptedEvents: [(String, String)] = []
    var declinedEvents: [String] = []
    var failedEvents: [(String, String)] = []
    var relaunchedEvents: [(String, String, Bool)] = []
    var completedEvents: [(reason: String, scope: String, attemptID: String, source: String)] = []
    var lastAcceptedAttemptID: String?
    var lastFailedAttemptID: String?
    var lastFailedInstallResolution: String?
    var lastRelaunchedInstallResolution: String?
    func offered(reason: String, destinationScope: String) {
      offeredEvents.append((reason, destinationScope))
    }
    func accepted(reason: String, destinationScope: String, attemptID: String) {
      acceptedEvents.append((reason, destinationScope))
      lastAcceptedAttemptID = attemptID
    }
    func declined(reason: String) { declinedEvents.append(reason) }
    func failed(
      reason: String, failureClass: String, attemptID: String, installResolution: String
    ) {
      failedEvents.append((reason, failureClass))
      lastFailedAttemptID = attemptID
      lastFailedInstallResolution = installResolution
    }
    func completed(
      reason: String, destinationScope: String, attemptID: String, completionSource: String
    ) {
      completedEvents.append((reason, destinationScope, attemptID, completionSource))
    }
    func relaunched(
      reason: String, destinationScope: String, relaunchConfirmed: Bool, attemptID: String,
      installResolution: String
    ) {
      relaunchedEvents.append((reason, destinationScope, relaunchConfirmed))
      lastRelaunchedInstallResolution = installResolution
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
    relaunchReason: String? = nil,
    relaunchDestinationScope: String? = nil,
    relaunchExpectedPath: String? = nil,
    relaunchExpectedVersion: String? = nil,
    moverResult: Result<InstallResolution, RelocationFailure> = .success(
      .installed(URL(fileURLWithPath: "/Applications/EnviousWispr.app"), bundleVersion: "1.0")),
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
        currentVersion: version, relaunchAttemptID: relaunchAttemptID,
        relaunchReason: relaunchReason, relaunchDestinationScope: relaunchDestinationScope,
        relaunchExpectedPath: relaunchExpectedPath,
        relaunchExpectedVersion: relaunchExpectedVersion),
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

  // MARK: Child completion is claimed ONLY by the copy we actually placed

  /// A real, existing, writable path so the detector reports `.healthy`. With
  /// a non-existent path the child is unhealthy and every "no completion"
  /// assertion would pass VACUOUSLY, proving nothing about the guard.
  private static var placedURL: URL { healthyURL }
  private static var placedPath: String { placedURL.standardizedFileURL.path }

  @Test("the expected child emits completed")
  func childCompletedWhenItIsTheExpectedCopy() async {
    let h = Self.makeHarness(
      bundleURL: Self.placedURL, version: "2.3.0",
      relaunchAttemptID: "attempt-1", relaunchReason: "translocated",
      relaunchDestinationScope: "system_applications",
      relaunchExpectedPath: Self.placedPath, relaunchExpectedVersion: "2.3.0")
    h.coordinator.evaluateAndOfferIfNeeded()
    await h.coordinator.pendingWork?.value
    #expect(h.telemetry.completedEvents.count == 1)
    #expect(h.telemetry.completedEvents.first?.source == "child_health")
    #expect(h.handshake.writes.first?.healthy == true)
  }

  @Test("a healthy child at ANOTHER path writes its ack but claims NO completion")
  func childAtWrongPathDoesNotClaimCompletion() async {
    // Launch Services can route an open request to a different registered copy.
    // That copy is healthy, so without this guard it would report success for
    // an attempt the parent is about to fail as ackPathMismatch — one attempt
    // counted as BOTH, corrupting the success rate (whole-diff review P2).
    let h = Self.makeHarness(
      bundleURL: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
      version: "2.3.0", relaunchAttemptID: "attempt-1", relaunchReason: "translocated",
      relaunchDestinationScope: "system_applications",
      relaunchExpectedPath: Self.placedPath, relaunchExpectedVersion: "2.3.0")
    h.coordinator.evaluateAndOfferIfNeeded()
    await h.coordinator.pendingWork?.value
    #expect(h.telemetry.completedEvents.isEmpty)
    // The health ack is safety-critical and must STILL be written.
    #expect(h.handshake.writes.count == 1)
  }

  @Test("a healthy child of the RIGHT path but wrong version claims no completion")
  func childWithWrongVersionDoesNotClaimCompletion() async {
    let h = Self.makeHarness(
      bundleURL: Self.placedURL, version: "9.9.9",
      relaunchAttemptID: "attempt-1", relaunchReason: "translocated",
      relaunchDestinationScope: "system_applications",
      relaunchExpectedPath: Self.placedPath, relaunchExpectedVersion: "2.3.0")
    h.coordinator.evaluateAndOfferIfNeeded()
    await h.coordinator.pendingWork?.value
    #expect(h.telemetry.completedEvents.isEmpty)
    #expect(h.handshake.writes.count == 1)
  }

  @Test("an OLD parent's child still acks, and simply emits nothing")
  func childFromOldParentStillAcks() async {
    let h = Self.makeHarness(
      bundleURL: Self.placedURL, relaunchAttemptID: "attempt-1")
    h.coordinator.evaluateAndOfferIfNeeded()
    await h.coordinator.pendingWork?.value
    #expect(h.telemetry.completedEvents.isEmpty)
    #expect(h.handshake.writes.count == 1)
    #expect(h.handshake.writes.first?.healthy == true)
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
    #expect(h.terminate.count == 0)  // healthy child lives on as the new app
  }

  @Test("relaunch child: still-blocked destination writes UNhealthy ack (A2 no masking)")
  func childAckStillBad() async {
    let h = Self.makeHarness(bundleURL: Self.translocatedURL, relaunchAttemptID: "attempt-1")
    h.coordinator.evaluateAndOfferIfNeeded()
    await h.coordinator.pendingWork?.value
    #expect(h.handshake.writes.count == 1)
    #expect(h.handshake.writes.first?.healthy == false)
    // Still-blocked child quits itself; the original stays the authoritative
    // copy (cloud #1490). Never two blocked instances.
    #expect(h.terminate.count == 1)
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

  @Test("ack unconfirmed -> original NEVER terminates, and reports the SPECIFIC reason")
  func moveAckTimeout() async {
    let h = Self.makeHarness(bundleURL: Self.translocatedURL)
    // A read-only-volume child: unhealthy for a reason that is NOT translocation.
    h.handshake.outcome = .unhealthy(stateLabel: "read_only_volume")
    h.coordinator.evaluateAndOfferIfNeeded()
    await h.coordinator.pendingWork?.value
    #expect(h.terminate.count == 0)  // the only known-good copy stays alive
    #expect(h.telemetry.relaunchedEvents.isEmpty)
    // #2006: this used to be the single `relaunchUnconfirmed` bucket for four
    // distinct conditions. The class is now specific, and the user gets
    // Message A because an unhealthy child is NOT evidence of a good copy.
    #expect(h.telemetry.failedEvents.map(\.1) == ["ackUnhealthyOther"])
    #expect(h.presenter.presentations.count == 1)
    if case .nothingMoved(let f) = h.presenter.presentations[0] {
      #expect(f == .ackUnhealthyOther)
    } else {
      Issue.record("an unhealthy child must never produce Message B")
    }
  }

  @Test("a STILL-TRANSLOCATED child is classified apart, and never told to just open it")
  func moveAckStillTranslocated() async {
    let h = Self.makeHarness(bundleURL: Self.translocatedURL)
    h.handshake.outcome = .unhealthy(stateLabel: "translocated")
    h.coordinator.evaluateAndOfferIfNeeded()
    await h.coordinator.pendingWork?.value
    #expect(h.terminate.count == 0)
    #expect(h.telemetry.failedEvents.map(\.1) == ["ackUnhealthyTranslocated"])
    // The loop person A repeated four times: "open it from Applications" when
    // the Applications copy is itself still trapped. Must be Message A.
    if case .nothingMoved = h.presenter.presentations[0] {} else {
      Issue.record("a still-translocated child must never produce Message B")
    }
  }

  @Test("a healthy ack that never arrives DOES offer the Applications copy")
  func moveAckTimedOutOffersDestination() async {
    let h = Self.makeHarness(bundleURL: Self.translocatedURL)
    h.handshake.outcome = .timedOut
    h.coordinator.evaluateAndOfferIfNeeded()
    await h.coordinator.pendingWork?.value
    #expect(h.terminate.count == 0)
    #expect(h.telemetry.failedEvents.map(\.1) == ["ackTimeout"])
    // Placed and signature-verified, no evidence of breakage -> Message B,
    // carrying the destination so Show in Finder has a real target.
    if case .installedNotConfirmed(_, let url) = h.presenter.presentations[0] {
      #expect(url.path == "/Applications/EnviousWispr.app")
    } else {
      Issue.record("a timed-out ack on a verified copy should produce Message B")
    }
  }

  @Test("the expected version comes from the MOVER, not the running app")
  func expectedVersionComesFromMover() async {
    // A NEWER copy already at the destination is explicitly allowed. If the
    // parent compared against its own version, this would be reported as a
    // mismatch and the user told to quit every copy — a false failure.
    let h = Self.makeHarness(
      bundleURL: Self.translocatedURL,
      moverResult: .success(
        .existingUsable(
          URL(fileURLWithPath: "/Applications/EnviousWispr.app"), bundleVersion: "9.9")))
    h.coordinator.evaluateAndOfferIfNeeded()
    await h.coordinator.pendingWork?.value
    #expect(h.handshake.lastExpectedVersion == "9.9")
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
      bundleURL: Self.translocatedURL, moverResult: .success(.existingUsable(dest, bundleVersion: "1.0")))
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
      bundleURL: Self.translocatedURL, moverResult: .success(.existingRunning(dest, bundleVersion: "1.0")))
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
      bundleURL: Self.translocatedURL, moverResult: .success(.existingRunning(dest, bundleVersion: "1.0")))
    h.relauncher.activateSuccess = false
    h.coordinator.evaluateAndOfferIfNeeded()
    await h.coordinator.pendingWork?.value
    #expect(h.terminate.count == 0)
    #expect(h.telemetry.failedEvents.map(\.1) == ["relaunchRejected"])
  }
}
