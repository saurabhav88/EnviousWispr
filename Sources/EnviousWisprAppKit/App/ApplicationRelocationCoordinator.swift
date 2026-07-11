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
public enum RelocationFailure: String, Error, Sendable {
  case destinationCreation
  case destinationRunning
  case stagingCopy
  case stagedBundleInvalid
  case signatureInvalid
  case destinationConflict
  case diskFull
  case relaunchRejected
  case relaunchUnconfirmed
  case unknown
}

/// What the mover did with the chosen destination.
public enum InstallResolution: Equatable, Sendable {
  /// We staged, validated, and placed our own copy at this URL.
  case installed(URL)
  /// A same-identity, same-or-newer healthy copy already existed here; the
  /// coordinator should simply open it rather than overwrite.
  case existingUsable(URL)

  public var url: URL {
    switch self {
    case .installed(let u), .existingUsable(let u): return u
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

  public init(
    bundleURL: URL, bundleIdentifier: String, currentVersion: String,
    relaunchAttemptID: String?
  ) {
    self.bundleURL = bundleURL
    self.bundleIdentifier = bundleIdentifier
    self.currentVersion = currentVersion
    self.relaunchAttemptID = relaunchAttemptID
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
      relaunchAttemptID: attemptID)
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
  func showFailure(_ failure: RelocationFailure)
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
  func relaunch(_ installedURL: URL, attemptID: String) async -> Bool
}

/// Waits (signal-based, bounded) for the relaunched copy to write its health
/// ack. Returns true only when the new instance reports healthy at the exact
/// destination for THIS attempt.
public protocol RelocationHandshaking: Sendable {
  func awaitAck(attemptID: String, destination: URL, timeout: TimeInterval) async -> Bool
  /// Called by the relaunched child to report its own health (A2).
  func writeAck(attemptID: String, resolvedPath: String, healthy: Bool)
}

/// Bounded `update.relocation_*` telemetry. Live impl forwards to
/// `TelemetryService` (also `@MainActor`) synchronously; tests record.
@MainActor public protocol RelocationTelemetrySink {
  func offered(reason: String, destinationScope: String)
  func accepted(reason: String, destinationScope: String)
  func declined(reason: String)
  func failed(reason: String, failureClass: String)
  func relaunched(reason: String, destinationScope: String, relaunchConfirmed: Bool)
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
      handshake.writeAck(
        attemptID: attemptID,
        resolvedPath: env.bundleURL.standardizedFileURL.path,
        healthy: state == .healthy)
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
      telemetry.accepted(reason: reason, destinationScope: destination.scope)
      await performMove(reason: reason, destination: destination)
    }
  }

  private func performMove(reason: String, destination: Destination) async {
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
      telemetry.failed(reason: reason, failureClass: failure.rawValue)
      presenter.showFailure(failure)
    case .success(let resolution):
      await relaunchAndHandOff(
        reason: reason, destination: destination, installedURL: resolution.url)
    }
  }

  /// Relaunch, then wait for the new instance's health ack BEFORE terminating
  /// the current (only known-good) process. NSWorkspace acceptance alone is not
  /// a sufficient handoff boundary (A1).
  private func relaunchAndHandOff(reason: String, destination: Destination, installedURL: URL) async
  {
    let attemptID = makeAttemptID()
    guard await relauncher.relaunch(installedURL, attemptID: attemptID) else {
      presenter.dismissProgress()
      telemetry.failed(reason: reason, failureClass: RelocationFailure.relaunchRejected.rawValue)
      presenter.showFailure(.relaunchRejected)
      return
    }

    let confirmed = await handshake.awaitAck(
      attemptID: attemptID, destination: installedURL, timeout: handshakeTimeout)
    guard confirmed else {
      // The new copy never confirmed healthy at the destination. Keep the
      // current process alive rather than strand the user with no working app.
      presenter.dismissProgress()
      telemetry.failed(
        reason: reason, failureClass: RelocationFailure.relaunchUnconfirmed.rawValue)
      presenter.showFailure(.relaunchUnconfirmed)
      return
    }

    telemetry.relaunched(
      reason: reason, destinationScope: destination.scope, relaunchConfirmed: true)
    // A5: best-effort, non-blocking flush; never delays the handoff.
    flushTelemetry()
    terminate()
  }
}
