import AppKit
import Darwin
import EnviousWisprServices
import Foundation
import Security

// Issue #1451: one-click recovery from macOS App Translocation.
//
// When macOS runs a still-quarantined EnviousWispr from a randomized read-only
// mount (launched off a DMG or from ~/Downloads without being moved in Finder),
// Sparkle aborts before it even fetches the appcast — 14 production users could
// never auto-update and got no explanation. This coordinator detects only the
// conditions Sparkle itself treats as update-blocking, offers a one-click move
// into a writable Applications folder, relaunches, and — critically — waits for
// the newly launched copy to hand back a health confirmation before the current
// (only known-good) process terminates. Every failure leaves the current
// process usable: this is a launch-time LIMB, never a prerequisite for menu-bar
// setup, hotkeys, dictation, or onboarding.
//
// Design + amendment rationale (handshake A1, presentation-only marker A2,
// atomic replace A3, signature validation A4, bounded flush A5, no original
// deletion A6, honest-scope A7, quarantine untouched): see
// docs/feature-requests/issue-1451-2026-07-10-app-translocation-recovery.md.

// MARK: - Location state

/// Whether the current bundle sits where Sparkle's pre-appcast location gate
/// would refuse to update. Mirrors pinned Sparkle 2.9.3 `SUHost` logic
/// (`SUHost.m:174` read-only, `:185` translocated). A Sparkle upgrade requires
/// re-validating this mapping (plan A7).
public enum ApplicationLocationState: Equatable, Sendable {
  /// Bundle is on a writable, non-translocated volume. Sparkle can update.
  case healthy
  /// Bundle path is under `/AppTranslocation/` (Sparkle code 1005).
  case translocated
  /// Bundle volume is `MNT_RDONLY`, e.g. a mounted DMG (Sparkle code 1003).
  case readOnlyVolume
  /// `statfs` failed. Fail open — never block launch on a detector error.
  case detectionFailed

  /// True only for the two conditions that actually block Sparkle updates.
  public var isUpdateBlocking: Bool {
    self == .translocated || self == .readOnlyVolume
  }

  /// Bounded, low-cardinality telemetry reason. `nil` when not update-blocking.
  public var reasonLabel: String? {
    switch self {
    case .translocated: return "translocated"
    case .readOnlyVolume: return "read_only_volume"
    case .healthy, .detectionFailed: return nil
    }
  }

  /// Label the relaunched child puts in its ack so the parent can say WHY the
  /// handoff failed. Unlike `reasonLabel` this is non-nil for every state,
  /// including `detectionFailed`, because an unhealthy child must always be
  /// classifiable rather than falling through as "malformed" (#2006 §3.2).
  public var ackStateLabel: String {
    switch self {
    case .healthy: return "healthy"
    case .translocated: return "translocated"
    case .readOnlyVolume: return "read_only_volume"
    case .detectionFailed: return "detection_failed"
    }
  }
}

/// Pure, injectable detector. Deliberately mirrors Sparkle's own observable
/// conditions rather than calling Sparkle's internal `SUHost` or the private
/// `SecTranslocate*` SPI (no public SDK header, no macOS 14–26 availability
/// contract).
public struct ApplicationLocationDetector: Sendable {
  public init() {}

  public func state(for bundleURL: URL) -> ApplicationLocationState {
    let standardizedPath = bundleURL.standardizedFileURL.path
    // Path-segment match, not substring — a user folder literally named
    // "AppTranslocation" elsewhere in the path must not false-positive.
    if standardizedPath.split(separator: "/").contains("AppTranslocation") {
      return .translocated
    }
    var fileSystem = statfs()
    let ok = bundleURL.path.withCString { statfs($0, &fileSystem) }
    guard ok == 0 else { return .detectionFailed }
    if (UInt32(fileSystem.f_flags) & UInt32(MNT_RDONLY)) != 0 {
      return .readOnlyVolume
    }
    return .healthy
  }
}

// MARK: - Outcomes

/// Bounded failure classification for UX copy, logs, and telemetry. No raw
/// paths, usernames, or free-form filesystem detail crosses this boundary.
public enum RelocationFailure: String, Error, Sendable, CaseIterable {
  case destinationCreation
  case destinationRunning
  case stagingCopy
  case stagedBundleInvalid
  case signatureInvalid
  case destinationConflict
  case diskFull
  /// Quarantine removal failed on the staged copy, before placement. Staging is
  /// discarded by `install`'s `defer`, so nothing was placed (#2006).
  case stripFailedBeforePlacement
  /// Quarantine removal failed on a bundle already at the destination, which we
  /// therefore may have left partially stripped. Never invite the user to open
  /// that copy (#2006).
  case stripFailedAtDestination
  case relaunchRejected
  // The six ack-specific cases below REPLACE the former `relaunchUnconfirmed`,
  // which collapsed four distinct conditions into one label and so told every
  // user the same untrue sentence. Classification is only derivable where the
  // ack is read, so `RelocationHandshaking` owns it (#2006 §3.2).
  /// Child ran and is STILL translocated: the move did not free it.
  case ackUnhealthyTranslocated
  /// Child ran and reported some other unhealthy state, or an old child
  /// reported unhealthy without naming a state.
  case ackUnhealthyOther
  /// Healthy child, but running from a path that is not the destination.
  case ackPathMismatch
  /// Healthy child at the right path reporting a DIFFERENT version: another
  /// registered copy answered instead of the one we placed.
  case ackVersionMismatch
  /// An ack appeared but could not be decoded.
  case ackMalformed
  /// No decodable ack before the deadline. The only class implicating
  /// `handshakeTimeout`.
  case ackTimeout
  case unknown
}

/// How the handshake ended. Replaces a `Bool` that could not distinguish the
/// four conditions the parent then had to guess between (#2006 §3.2).
public enum RelocationAckOutcome: Equatable, Sendable {
  case confirmed
  case unhealthy(stateLabel: String?)
  case pathMismatch
  case versionMismatch
  case malformed
  case timedOut

  /// The single mapping from outcome to taxonomy, so no call site invents one.
  public var failure: RelocationFailure {
    switch self {
    case .confirmed: return .unknown  // never used; `confirmed` is not a failure
    case .unhealthy(let label):
      return label == ApplicationLocationState.translocated.reasonLabel
        ? .ackUnhealthyTranslocated : .ackUnhealthyOther
    case .pathMismatch: return .ackPathMismatch
    case .versionMismatch: return .ackVersionMismatch
    case .malformed: return .ackMalformed
    case .timedOut: return .ackTimeout
    }
  }
}

/// What the user is shown, and whether a Finder button is even possible.
///
/// Founder decision 2026-08-10 (#2006 §3.3): user-facing copy is TWO families,
/// not one per failure class. Binding the family to the Finder affordance in a
/// single type makes them impossible to mis-pair — `.nothingMoved` structurally
/// cannot carry a destination and `.installedNotConfirmed` structurally cannot
/// lack one. It does NOT prove the correct family was chosen; that is enforced
/// by the 18-origin routing test.
public enum RelocationFailurePresentation: Equatable, Sendable {
  /// Message A. Nothing usable was placed, OR a placed copy is known/suspected
  /// unhealthy and must never be offered for opening.
  case nothingMoved(RelocationFailure)
  /// Message B. A verified copy is at the destination and only the handoff is
  /// unconfirmed.
  case installedNotConfirmed(RelocationFailure, destination: URL)

  public var failure: RelocationFailure {
    switch self {
    case .nothingMoved(let f), .installedNotConfirmed(let f, _): return f
    }
  }
}

/// What the mover did with the chosen destination.
public enum InstallResolution: Equatable, Sendable {
  /// We staged, validated, and placed our own copy at this URL → launch fresh +
  /// handshake.
  case installed(URL, bundleVersion: String)
  /// A same-identity, same-or-newer healthy copy already exists here but is NOT
  /// running → launch it fresh + handshake.
  case existingUsable(URL, bundleVersion: String)
  /// A same-identity, same-or-newer healthy copy is ALREADY RUNNING here →
  /// activate that instance and terminate self; never spawn a duplicate, and no
  /// handshake is needed (the copy is verified and already live). Cloud Codex
  /// review #1490.
  case existingRunning(URL, bundleVersion: String)

  public var url: URL {
    switch self {
    case .installed(let u, _), .existingUsable(let u, _), .existingRunning(let u, _): return u
    }
  }

  /// The version the MOVER observed on the bundle it decided to launch. The
  /// only authority for the expected ack version: `.existingUsable`
  /// deliberately accepts a same-or-NEWER destination, so comparing against the
  /// running app's own version would reject a valid newer copy (#2006 §3.2).
  public var bundleVersion: String {
    switch self {
    case .installed(_, let v), .existingUsable(_, let v), .existingRunning(_, let v): return v
    }
  }

  /// True only for the route that launches no child and needs no handshake.
  public var isExistingRunning: Bool {
    if case .existingRunning = self { return true }
    return false
  }

  /// Bounded telemetry label for which route the mover took.
  public var telemetryLabel: String {
    switch self {
    case .installed: return "installed"
    case .existingUsable: return "existing_usable"
    case .existingRunning: return "existing_running"
    }
  }
}

/// Terminal result of one launch-time evaluation.
public enum ApplicationRelocationOutcome: Equatable, Sendable {
  case notNeeded
  case suppressed
  case declined
  case relaunched(destination: URL)
  case continuedAfterFailure(RelocationFailure)
}

/// User's answer to the one-click prompt.
public enum RelocationChoice: Equatable, Sendable {
  case move
  case notNow
}

// MARK: - Seams

/// Launch-time facts. Injected so tests never read the real process bundle or
/// environment.
public struct RelocationEnvironment: Sendable {
  public let bundleURL: URL
  public let bundleIdentifier: String
  public let currentVersion: String
  /// Non-nil when THIS process is the relaunched copy (A1/A2): the attempt ID
  /// the original passed via `EW_RELOCATION_ATTEMPT_ID`. Presence means "report
  /// your health back, do not prompt."
  public let relaunchAttemptID: String?
  /// Attempt context the parent passes through so the CHILD can emit its own
  /// `completed` event. Both are nil when an OLD parent launched us; that must
  /// suppress only the telemetry, never the health ack (#2006 §9).
  public let relaunchReason: String?
  public let relaunchDestinationScope: String?

  public init(
    bundleURL: URL, bundleIdentifier: String, currentVersion: String,
    relaunchAttemptID: String?, relaunchReason: String? = nil,
    relaunchDestinationScope: String? = nil
  ) {
    self.bundleURL = bundleURL
    self.bundleIdentifier = bundleIdentifier
    self.currentVersion = currentVersion
    self.relaunchAttemptID = relaunchAttemptID
    self.relaunchReason = relaunchReason
    self.relaunchDestinationScope = relaunchDestinationScope
  }

  /// Production environment read from the running process.
  @MainActor public static func live() -> RelocationEnvironment {
    let env = ProcessInfo.processInfo.environment
    let isRelaunch = env["EW_RELOCATION_RELAUNCH"] == "1"
    let attemptID = isRelaunch ? env["EW_RELOCATION_ATTEMPT_ID"] : nil
    let version =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    return RelocationEnvironment(
      bundleURL: Bundle.main.bundleURL,
      bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.enviouswispr.app",
      currentVersion: version,
      relaunchAttemptID: attemptID,
      relaunchReason: isRelaunch ? env["EW_RELOCATION_REASON"] : nil,
      relaunchDestinationScope: isRelaunch ? env["EW_RELOCATION_DESTINATION_SCOPE"] : nil)
  }
}

/// Persists the "Not Now" decline so healthy users are not nagged. Backed by
/// `UserDefaults` in production; a fake in tests.
public protocol RelocationSuppressionStore: Sendable {
  func lastDecline() -> (at: Date, version: String)?
  func recordDecline(at: Date, version: String)
  func clear()
}

/// Presents the one-click prompt and (later) progress/failure surfaces. Live
/// impl uses `NSAlert`; tests inject a scripted choice.
@MainActor public protocol RelocationPresenting {
  func present() async -> RelocationChoice
  func showProgress()
  func dismissProgress()
  func showFailure(_ presentation: RelocationFailurePresentation)
}

/// Copies + installs the bundle into the destination, resolving any existing
/// copy safely (atomic replace / backup-restore, never Trash-first). Runs its
/// blocking filesystem work off the main actor.
public protocol ApplicationMoving: Sendable {
  func install(
    source: URL, destination: URL,
    expectedBundleIdentifier: String, currentVersion: String
  ) async -> Result<InstallResolution, RelocationFailure>
}

/// Launches the installed copy with the relaunch marker + attempt ID.
public protocol RelocationRelaunching: Sendable {
  func relaunch(
    _ installedURL: URL, attemptID: String, reason: String, destinationScope: String
  ) async -> Bool
  /// Bring an ALREADY-running instance at this URL to the front (no new
  /// instance). Returns false if no such running instance is found.
  func activateRunning(_ url: URL) async -> Bool
}

/// Waits (signal-based, bounded) for the relaunched copy to write its health
/// ack. Returns true only when the new instance reports healthy at the exact
/// destination for THIS attempt.
public protocol RelocationHandshaking: Sendable {
  func awaitAck(
    attemptID: String, destination: URL, expectedBundleVersion: String, timeout: TimeInterval
  ) async -> RelocationAckOutcome
  /// Called by the relaunched child to report its own health (A2).
  /// `stateLabel` and `bundleVersion` are optional on the wire: an ack written
  /// by an OLDER child carries neither, and absence must mean UNKNOWN, never
  /// mismatch, or every cross-version handoff breaks (#2006 §4).
  func writeAck(
    attemptID: String, resolvedPath: String, healthy: Bool, stateLabel: String?,
    bundleVersion: String?)
}

/// Bounded `update.relocation_*` telemetry. Live impl forwards to
/// `TelemetryService` (also `@MainActor`) synchronously; tests record.
@MainActor public protocol RelocationTelemetrySink {
  func offered(reason: String, destinationScope: String)
  func accepted(reason: String, destinationScope: String, attemptID: String)
  func declined(reason: String)
  /// `installResolution` is `unresolved` when the mover failed BEFORE returning
  /// a resolution — the mover returns `Result<InstallResolution, _>`, so on a
  /// pre-placement failure no route exists to report (#2006 §3.4d).
  func failed(
    reason: String, failureClass: String, attemptID: String, installResolution: String)
  func relaunched(
    reason: String, destinationScope: String, relaunchConfirmed: Bool, attemptID: String,
    installResolution: String)
  /// Emitted by the healthy CHILD after its own health check, or by the parent
  /// after a successful `.existingRunning` activation, which launches no child.
  func completed(
    reason: String, destinationScope: String, attemptID: String, completionSource: String)
}

// MARK: - Coordinator

/// App-shell, process-lifecycle limb (owner of the whole relocation policy;
/// `AppLifecycleCoordinator` only calls it — plan §3b/§3c). Single authority for
/// detection, decline cadence, destination choice, move state, conflict
/// handling, the relaunch handshake, and termination ordering.
@MainActor
public final class ApplicationRelocationCoordinator {
  private let env: RelocationEnvironment
  private let detector: ApplicationLocationDetector
  private let suppression: RelocationSuppressionStore
  private let presenter: RelocationPresenting
  private let mover: any ApplicationMoving
  private let relauncher: any RelocationRelaunching
  private let handshake: any RelocationHandshaking
  private let telemetry: any RelocationTelemetrySink
  private let now: @Sendable () -> Date
  private let terminate: @MainActor () -> Void
  private let handshakeTimeout: TimeInterval
  /// A5: non-blocking, best-effort flush called just before terminate. PostHog's
  /// flush only schedules delivery and unsent events persist to disk, so this
  /// never delays the handoff and any straggler delivers from the relocated
  /// copy — strictly better than a blocking flush with a timeout.
  private let flushTelemetry: @MainActor () -> Void
  private let makeAttemptID: @Sendable () -> String

  /// Re-prompt cadence: a "Not Now" is honored for seven days or until the
  /// bundle version changes, whichever comes first.
  static let declineCooldown: TimeInterval = 7 * 24 * 60 * 60

  private var moveInProgress = false

  /// The scheduled presentation/move task from the most recent
  /// `evaluateAndOfferIfNeeded()`. Exposed so tests can deterministically await
  /// the full flow; production never reads it.
  private(set) var pendingWork: Task<Void, Never>?

  public init(
    env: RelocationEnvironment,
    detector: ApplicationLocationDetector,
    suppression: RelocationSuppressionStore,
    presenter: RelocationPresenting,
    mover: any ApplicationMoving,
    relauncher: any RelocationRelaunching,
    handshake: any RelocationHandshaking,
    telemetry: any RelocationTelemetrySink,
    now: @escaping @Sendable () -> Date = Date.init,
    terminate: @escaping @MainActor () -> Void,
    handshakeTimeout: TimeInterval = 8,
    flushTelemetry: @escaping @MainActor () -> Void = {},
    makeAttemptID: @escaping @Sendable () -> String = { UUID().uuidString }
  ) {
    self.env = env
    self.detector = detector
    self.suppression = suppression
    self.presenter = presenter
    self.mover = mover
    self.relauncher = relauncher
    self.handshake = handshake
    self.telemetry = telemetry
    self.now = now
    self.terminate = terminate
    self.handshakeTimeout = handshakeTimeout
    self.flushTelemetry = flushTelemetry
    self.makeAttemptID = makeAttemptID
  }

  /// Called once from `AppLifecycleCoordinator.runDidFinishLaunching()`. Returns
  /// immediately after scheduling any presentation; never blocks launch, copies,
  /// shells, hits the network, or waits for a relaunch inline.
  public func evaluateAndOfferIfNeeded() {
    var state = detector.state(for: env.bundleURL)

    #if DEBUG
      // DEBUG-only preview/UAT trigger: force a blocking state so the prompt
      // renders on an ordinary (healthy) dev launch. Compiled out of release, so
      // it can never affect shipped behavior. A real move is still gated by the
      // signature check, which a self-signed dev build fails — so this previews
      // the cards without risking an actual relocation.
      if let forced = ProcessInfo.processInfo.environment["EW_RELOCATION_FORCE_STATE"] {
        switch forced {
        case "translocated": state = .translocated
        case "readOnlyVolume": state = .readOnlyVolume
        case "healthy": state = .healthy
        default: break
        }
      }
    #endif

    // A1/A2: this process is the relaunched child. Report health via the ack
    // (detection STILL runs — the marker suppresses a second dialog, never
    // detection, so a failed move cannot masquerade as healthy) and return.
    if let attemptID = env.relaunchAttemptID {
      let healthy = state == .healthy
      // The ack is the ONLY channel by which the parent learns why a handoff
      // failed, so it carries the child's own state label and its version.
      // Version lets the parent tell "our copy came up" from "some other
      // registered copy answered" — Launch Services may route an open request
      // to an already-registered bundle (#2006 §3.2).
      handshake.writeAck(
        attemptID: attemptID,
        resolvedPath: env.bundleURL.standardizedFileURL.path,
        healthy: healthy,
        stateLabel: state.ackStateLabel,
        bundleVersion: env.currentVersion)
      // Telemetry metadata is best-effort and must NEVER gate the health ack
      // above: an OLD parent launches us without it, and a missing label must
      // cost only the `completed` event, never the handshake itself.
      if healthy, let reason = env.relaunchReason,
        let scope = env.relaunchDestinationScope
      {
        telemetry.completed(
          reason: reason, destinationScope: scope, attemptID: attemptID,
          completionSource: "child_health")
      }
      // If the move did not clear the blocking location, the original process
      // stays alive as the authoritative copy (its handshake fails). Quit this
      // redundant child rather than leave two blocked instances running (cloud
      // Codex review #1490). Healthy child lives on as the new app; the two
      // branches are mutually exclusive, so there is never zero or two copies.
      if !healthy { terminate() }
      return
    }

    guard state.isUpdateBlocking else {
      // A healthy launch clears any stale decline marker so a user who later
      // regresses is offered fresh.
      suppression.clear()
      return
    }

    guard !moveInProgress, shouldOffer(now: now()) else { return }
    guard let reason = state.reasonLabel else { return }

    let destination = Self.chooseDestination(appName: env.bundleURL.lastPathComponent)
    telemetry.offered(reason: reason, destinationScope: destination.scope)

    // Present on the next main-loop turn: the app can become active first, and
    // launch continues without awaiting this.
    pendingWork = Task { @MainActor [weak self] in
      await self?.presentAndHandle(state: state, destination: destination)
    }
  }

  // MARK: Cadence

  /// True when we may show the prompt: never declined, or the decline is stale
  /// (>7d) or from a different version. No permanent "don't ask again" — that
  /// would knowingly leave updates broken forever.
  func shouldOffer(now: Date) -> Bool {
    guard let decline = suppression.lastDecline() else { return true }
    if decline.version != env.currentVersion { return true }
    return now.timeIntervalSince(decline.at) >= Self.declineCooldown
  }

  // MARK: Destination

  struct Destination: Sendable {
    let url: URL
    let scope: String  // "system_applications" | "user_applications"
  }

  /// `/Applications` when directly writable by the current user (admins), else
  /// `~/Applications` (standard users). Never requests admin credentials.
  static func chooseDestination(appName: String) -> Destination {
    let system = URL(fileURLWithPath: "/Applications", isDirectory: true)
    if FileManager.default.isWritableFile(atPath: system.path) {
      return Destination(url: system.appendingPathComponent(appName), scope: "system_applications")
    }
    let userApps =
      FileManager.default.urls(for: .applicationDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
      .appendingPathComponent("Applications", isDirectory: true)
    return Destination(
      url: userApps.appendingPathComponent(appName), scope: "user_applications")
  }

  // MARK: Flow

  private func presentAndHandle(state: ApplicationLocationState, destination: Destination) async {
    guard let reason = state.reasonLabel else { return }
    switch await presenter.present() {
    case .notNow:
      suppression.recordDecline(at: now(), version: env.currentVersion)
      telemetry.declined(reason: reason)
    case .move:
      // Mint the id BEFORE `accepted` so the ingress event and every terminal
      // event share one join key. It used to be minted inside the relaunch
      // path, so `accepted` carried none and nothing could be joined to it —
      // which is why four accepted attempts in 30 d have no known outcome.
      let attemptID = makeAttemptID()
      telemetry.accepted(
        reason: reason, destinationScope: destination.scope, attemptID: attemptID)
      await performMove(reason: reason, destination: destination, attemptID: attemptID)
    }
  }

  private func performMove(reason: String, destination: Destination, attemptID: String) async {
    guard !moveInProgress else { return }
    moveInProgress = true
    defer { moveInProgress = false }

    presenter.showProgress()

    let result = await mover.install(
      source: env.bundleURL, destination: destination.url,
      expectedBundleIdentifier: env.bundleIdentifier, currentVersion: env.currentVersion)

    switch result {
    case .failure(let failure):
      presenter.dismissProgress()
      // No resolution exists: the mover returns Result<InstallResolution, _>,
      // so a pre-placement failure has no route to report (#2006 §3.4d).
      telemetry.failed(
        reason: reason, failureClass: failure.rawValue, attemptID: attemptID,
        installResolution: "unresolved")
      presenter.showFailure(Self.presentation(for: failure, destination: destination.url))
    case .success(let resolution) where resolution.isExistingRunning:
      // A verified same-or-newer copy is already running: bring it to the front
      // and terminate this translocated duplicate. No new instance, no
      // handshake (cloud Codex review #1490).
      await activateAndHandOff(
        reason: reason, destination: destination, resolution: resolution, attemptID: attemptID)
    case .success(let resolution):
      await relaunchAndHandOff(
        reason: reason, destination: destination, resolution: resolution, attemptID: attemptID)
    }
  }

  /// The sole A/B routing decision (#2006 §3.3). Message B requires positive
  /// evidence that a verified copy is present and not known-bad; every other
  /// origin gets Message A, whose instruction — drag it yourself — is safe in
  /// EVERY state. The asymmetry is deliberate: a wrong B invites the user to
  /// open a broken copy, a wrong A costs one redundant drag.
  static func presentation(for failure: RelocationFailure, destination: URL)
    -> RelocationFailurePresentation
  {
    switch failure {
    case .ackMalformed, .ackTimeout, .ackPathMismatch, .ackVersionMismatch, .relaunchRejected:
      return .installedNotConfirmed(failure, destination: destination)
    // Everything below is Message A. `stripFailedAtDestination` and both
    // unhealthy acks are placed-but-suspect, so they must NOT become B.
    case .destinationCreation, .destinationRunning, .stagingCopy, .stagedBundleInvalid,
      .signatureInvalid, .destinationConflict, .diskFull, .stripFailedBeforePlacement,
      .stripFailedAtDestination, .ackUnhealthyTranslocated, .ackUnhealthyOther, .unknown:
      return .nothingMoved(failure)
    }
  }

  /// The good copy is already running: activate it, then terminate self. If it
  /// cannot be activated, keep the current process alive and report failure.
  private func activateAndHandOff(
    reason: String, destination: Destination, resolution: InstallResolution, attemptID: String
  ) async {
    guard await relauncher.activateRunning(resolution.url) else {
      presenter.dismissProgress()
      telemetry.failed(
        reason: reason, failureClass: RelocationFailure.relaunchRejected.rawValue,
        attemptID: attemptID, installResolution: resolution.telemetryLabel)
      presenter.showFailure(
        Self.presentation(for: .relaunchRejected, destination: resolution.url))
      return
    }
    telemetry.relaunched(
      reason: reason, destinationScope: destination.scope, relaunchConfirmed: true,
      attemptID: attemptID, installResolution: resolution.telemetryLabel)
    // This route launches NO child, so a child-only `completed` would silently
    // drop the whole existing-running success path from the success rate.
    telemetry.completed(
      reason: reason, destinationScope: destination.scope, attemptID: attemptID,
      completionSource: "existing_running_activation")
    flushTelemetry()
    terminate()
  }

  /// Relaunch, then wait for the new instance's health ack BEFORE terminating
  /// the current (only known-good) process. NSWorkspace acceptance alone is not
  /// a sufficient handoff boundary (A1).
  private func relaunchAndHandOff(
    reason: String, destination: Destination, resolution: InstallResolution, attemptID: String
  ) async {
    let installedURL = resolution.url
    guard
      await relauncher.relaunch(
        installedURL, attemptID: attemptID, reason: reason,
        destinationScope: destination.scope)
    else {
      presenter.dismissProgress()
      telemetry.failed(
        reason: reason, failureClass: RelocationFailure.relaunchRejected.rawValue,
        attemptID: attemptID, installResolution: resolution.telemetryLabel)
      presenter.showFailure(Self.presentation(for: .relaunchRejected, destination: installedURL))
      return
    }

    // Expected version comes from the MOVER's resolution, never from
    // env.currentVersion: `.existingUsable` accepts a same-or-newer copy, so
    // the destination's version can legitimately exceed ours (#2006 §3.2).
    let outcome = await handshake.awaitAck(
      attemptID: attemptID, destination: installedURL,
      expectedBundleVersion: resolution.bundleVersion, timeout: handshakeTimeout)
    guard outcome == .confirmed else {
      // The new copy never confirmed healthy at the destination. Keep the
      // current process alive rather than strand the user with no working app.
      presenter.dismissProgress()
      let failure = outcome.failure
      telemetry.failed(
        reason: reason, failureClass: failure.rawValue, attemptID: attemptID,
        installResolution: resolution.telemetryLabel)
      presenter.showFailure(Self.presentation(for: failure, destination: installedURL))
      return
    }

    telemetry.relaunched(
      reason: reason, destinationScope: destination.scope, relaunchConfirmed: true,
      attemptID: attemptID, installResolution: resolution.telemetryLabel)
    // A5: best-effort, non-blocking flush; never delays the handoff.
    flushTelemetry()
    terminate()
  }
}
