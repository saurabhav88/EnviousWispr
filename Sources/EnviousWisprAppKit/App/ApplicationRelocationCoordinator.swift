import AppKit
import Darwin
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
// process usable. A due update-blocking launch waits for the offer and move
// outcome before normal startup (#3252); every non-handoff outcome permits
// normal startup, and healthy and offer-not-due launches proceed immediately.
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
enum ApplicationLocationState: Equatable, Sendable {
  /// Bundle is on a writable, non-translocated volume. Sparkle can update.
  case healthy
  /// Bundle path is under `/AppTranslocation/` (Sparkle code 1005).
  case translocated
  /// Bundle volume is `MNT_RDONLY`, e.g. a mounted DMG (Sparkle code 1003).
  case readOnlyVolume
  /// `statfs` failed. Fail open — never block launch on a detector error.
  case detectionFailed

  /// True only for the two conditions that actually block Sparkle updates.
  var isUpdateBlocking: Bool {
    self == .translocated || self == .readOnlyVolume
  }

  /// Bounded, low-cardinality telemetry reason. `nil` when not update-blocking.
  var reasonLabel: String? {
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
  var ackStateLabel: String {
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
struct ApplicationLocationDetector: Sendable {
  init() {}

  func state(for bundleURL: URL) -> ApplicationLocationState {
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
  /// that copy (#2006). Arises ONLY on the `.existingUsable` route.
  case stripFailedAtDestination
  /// The post-placement verification of OUR freshly placed copy failed. A copy
  /// IS at the destination and may be unclean. Distinct from
  /// `stripFailedAtDestination` because the route differs and therefore so
  /// does `install_resolution` — reusing that case reported a fresh install as
  /// `existing_usable` (cloud review, second round).
  case stripFailedAfterPlacement
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
  /// The whole move (install, launch and acknowledgement) did not finish before the
  /// pre-flight watchdog expired, so the current process was kept (#3252, plan 3.7). Nothing
  /// is known to be placed, so it is reported as Message A.
  case installTimedOut
  case unknown

  /// The install route this failure ITSELF identifies, for the terminal events
  /// where the mover returned no resolution to read.
  ///
  /// Only `stripFailedAtDestination` identifies one: it can arise ONLY on the
  /// `.existingUsable` route, where a verified copy was already at the
  /// destination. Reporting it as `unresolved` would erase exactly the
  /// existing-copy distinction this field exists to measure, and make the
  /// repeat path indistinguishable from a failure before any destination was
  /// resolved (whole-diff review r4). No `default` arm on purpose: a future
  /// case must answer this question rather than inherit `unresolved`.
  public var impliedInstallResolution: String {
    switch self {
    case .stripFailedAtDestination:
      return InstallResolution.TelemetryLabel.existingUsable
    case .stripFailedAfterPlacement:
      // We placed this copy ourselves; the route is `installed`.
      return InstallResolution.TelemetryLabel.installed
    case .destinationCreation, .destinationRunning, .stagingCopy, .stagedBundleInvalid,
      .signatureInvalid, .destinationConflict, .diskFull, .stripFailedBeforePlacement,
      .relaunchRejected, .ackUnhealthyTranslocated, .ackUnhealthyOther, .ackPathMismatch,
      .ackVersionMismatch, .ackMalformed, .ackTimeout, .installTimedOut, .unknown:
      return InstallResolution.TelemetryLabel.unresolved
    }
  }
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
enum RelocationFailurePresentation: Equatable, Sendable {
  /// Message A. Nothing usable was placed, OR a placed copy is known/suspected
  /// unhealthy and must never be offered for opening.
  case nothingMoved(RelocationFailure)
  /// Message B. A verified copy is at the destination and only the handoff is
  /// unconfirmed.
  case installedNotConfirmed(RelocationFailure, destination: URL)

  var failure: RelocationFailure {
    switch self {
    case .nothingMoved(let f), .installedNotConfirmed(let f, _): return f
    }
  }
}

/// What the mover did with the chosen destination.
enum InstallResolution: Equatable, Sendable {
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

  var url: URL {
    switch self {
    case .installed(let u, _), .existingUsable(let u, _), .existingRunning(let u, _): return u
    }
  }

  /// The version the MOVER observed on the bundle it decided to launch. The
  /// only authority for the expected ack version: `.existingUsable`
  /// deliberately accepts a same-or-NEWER destination, so comparing against the
  /// running app's own version would reject a valid newer copy (#2006 §3.2).
  var bundleVersion: String {
    switch self {
    case .installed(_, let v), .existingUsable(_, let v), .existingRunning(_, let v): return v
    }
  }

  /// True only for the route that launches no child and needs no handshake.
  var isExistingRunning: Bool {
    if case .existingRunning = self { return true }
    return false
  }

  /// One home for the bounded `install_resolution` vocabulary, so the failure
  /// path and the success path cannot drift apart.
  enum TelemetryLabel {
    static let installed = "installed"
    static let existingUsable = "existing_usable"
    static let existingRunning = "existing_running"
    /// The mover failed BEFORE producing any resolution. Asserts nothing about
    /// whether a destination existed.
    static let unresolved = "unresolved"
  }

  /// Bounded telemetry label for which route the mover took.
  var telemetryLabel: String {
    switch self {
    case .installed: return TelemetryLabel.installed
    case .existingUsable: return TelemetryLabel.existingUsable
    case .existingRunning: return TelemetryLabel.existingRunning
    }
  }
}

/// User's answer to the one-click prompt.
enum RelocationChoice: Equatable, Sendable {
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
  /// The path and version the PARENT expects this child to be. The child emits
  /// `completed` only when it matches BOTH, so a different registered copy that
  /// Launch Services happened to open cannot report success for an attempt the
  /// parent is about to fail (whole-diff review P2, #2006).
  public let relaunchExpectedPath: String?
  public let relaunchExpectedVersion: String?

  public init(
    bundleURL: URL, bundleIdentifier: String, currentVersion: String,
    relaunchAttemptID: String?, relaunchReason: String? = nil,
    relaunchDestinationScope: String? = nil, relaunchExpectedPath: String? = nil,
    relaunchExpectedVersion: String? = nil
  ) {
    self.bundleURL = bundleURL
    self.bundleIdentifier = bundleIdentifier
    self.currentVersion = currentVersion
    self.relaunchAttemptID = relaunchAttemptID
    self.relaunchReason = relaunchReason
    self.relaunchDestinationScope = relaunchDestinationScope
    self.relaunchExpectedPath = relaunchExpectedPath
    self.relaunchExpectedVersion = relaunchExpectedVersion
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
      relaunchDestinationScope: isRelaunch ? env["EW_RELOCATION_DESTINATION_SCOPE"] : nil,
      relaunchExpectedPath: isRelaunch ? env["EW_RELOCATION_EXPECTED_PATH"] : nil,
      relaunchExpectedVersion: isRelaunch ? env["EW_RELOCATION_EXPECTED_VERSION"] : nil)
  }
}

/// Persists the "Not Now" decline so healthy users are not nagged. Backed by
/// `UserDefaults` in production; a fake in tests.
protocol RelocationSuppressionStore: Sendable {
  func lastDecline() -> (at: Date, version: String)?
  func recordDecline(at: Date, version: String)
  func clear()
}

/// Presents the one-click prompt and (later) progress/failure surfaces. Live
/// impl uses `NSAlert`; tests inject a scripted choice.
@MainActor protocol RelocationPresenting {
  func present() async -> RelocationChoice
  func showProgress()
  func dismissProgress()
  func showFailure(_ presentation: RelocationFailurePresentation)
}

/// Copies + installs the bundle into the destination, resolving any existing
/// copy safely (atomic replace / backup-restore, never Trash-first). Runs its
/// blocking filesystem work off the main actor.
protocol ApplicationMoving: Sendable {
  func install(
    source: URL, destination: URL,
    expectedBundleIdentifier: String, currentVersion: String
  ) async -> Result<InstallResolution, RelocationFailure>
}

/// Launches the installed copy with the relaunch marker + attempt ID.
public protocol RelocationRelaunching: Sendable {
  func relaunch(
    _ installedURL: URL, attemptID: String, reason: String, destinationScope: String,
    expectedBundleVersion: String
  ) async -> Bool
  /// Bring an ALREADY-running instance at this URL to the front (no new
  /// instance). Returns false if no such running instance is found.
  func activateRunning(_ url: URL) async -> Bool
}

/// Waits (signal-based, bounded) for the relaunched copy to write its health
/// ack. Returns true only when the new instance reports healthy at the exact
/// destination for THIS attempt.
protocol RelocationHandshaking: Sendable {
  func awaitAck(
    attemptID: String, destination: URL, expectedBundleVersion: String, timeout: TimeInterval
  ) async -> RelocationAckOutcome
  /// Called by the relaunched child to report its own health (A2).
  /// `stateLabel` and `bundleVersion` are optional on the wire: an ack written
  /// by an OLDER child carries neither, and absence must mean UNKNOWN, never
  /// mismatch, or every cross-version handoff breaks (#2006 §4).
  /// Returns whether the ack was actually PUBLISHED. A silent failure here
  /// (unwritable Application Support, full disk) means the parent will never
  /// see it and will time out, so the child must not then claim success.
  @discardableResult
  func writeAck(
    attemptID: String, resolvedPath: String, healthy: Bool, stateLabel: String?,
    bundleVersion: String?) -> Bool
}

/// Bounded `update.relocation_*` telemetry. Live impl forwards to
/// `TelemetryService` (also `@MainActor`) synchronously; tests record.
@MainActor protocol RelocationTelemetrySink {
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

// MARK: - Launch decision and hand-off authority (#3252)

/// What the launch should do about the move offer (plan 3.2). Pure and synchronous: value inputs
/// in, a value out. It never reads or writes the decline store; clearing a stale decline is
/// `reportLaunchState()`'s job (plan 3.6), so a blocked launch inside the cooldown keeps its
/// record.
enum LaunchDecision: Equatable, Sendable {
  /// Build and start the app exactly as before: a relaunched child, a location that does not
  /// block updates, or an offer that is not due.
  case proceed
  /// Show the offer before the app starts any work. The caller chooses the destination.
  case offerFirst(state: ApplicationLocationState)

  @MainActor
  static func decide(
    isRelaunchChild: Bool, state: ApplicationLocationState,
    lastDecline: (at: Date, version: String)?, currentVersion: String, now: Date
  ) -> LaunchDecision {
    if isRelaunchChild { return .proceed }
    guard state.isUpdateBlocking else { return .proceed }
    guard
      ApplicationRelocationCoordinator.offerIsDue(
        lastDecline: lastDecline, currentVersion: currentVersion, now: now)
    else { return .proceed }
    return .offerFirst(state: state)
  }
}

/// The single owner of "may this process advance a move, launch or activate a destination, and
/// terminate" (plan 3.4). `pending` becomes `committed` or `released`, once, and never goes
/// back. `commit()` is called only immediately before `terminate()`, with no suspension between
/// them. `release()` happens on every exit that does not hand off. After either, every later
/// attempt fails, which is what makes a late result inert.
@MainActor
final class HandoffAuthority {
  enum State: Equatable, Sendable { case pending, committed, released }

  private(set) var state: State = .pending
  var isPending: Bool { state == .pending }

  /// True only from `pending`.
  @discardableResult
  func commit() -> Bool {
    guard state == .pending else { return false }
    state = .committed
    return true
  }

  /// True only from `pending`.
  @discardableResult
  func release() -> Bool {
    guard state == .pending else { return false }
    state = .released
    return true
  }
}

/// How `runPreflight` ended (plan 3.4).
enum PreflightOutcome: Equatable, Sendable {
  /// Start the app normally, once. `failure` is the card to show AFTER the app has started
  /// (never before: it is modal, and its copy says the app keeps working).
  case continueNormally(failure: RelocationFailurePresentation?)
  /// The parent committed and requested termination. Do nothing more.
  case handedOff
}

// MARK: - Coordinator

/// App-shell, process-lifecycle limb (owner of the whole relocation policy;
/// `AppLifecycleCoordinator` only calls it — plan §3b/§3c). Single authority for
/// detection, decline cadence, destination choice, move state, conflict
/// handling, the relaunch handshake, and termination ordering.
@MainActor
final class ApplicationRelocationCoordinator {
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
  private let chooseDestination: @MainActor (String) -> Destination
  private let moveWatchdogSeconds: TimeInterval
  private let watchdogSleep: @Sendable (TimeInterval) async throws -> Void
  /// Whether the destination copy is still a running process. Checked immediately before the
  /// commit, so a child that wrote a healthy ack and then exited does not leave the person with
  /// no running app.
  private let destinationIsRunning: @MainActor (String, URL) -> Bool

  /// Re-prompt cadence: a "Not Now" is honored for seven days or until the
  /// bundle version changes, whichever comes first.
  static let declineCooldown: TimeInterval = 7 * 24 * 60 * 60

  /// PLACEHOLDER, NOT empirically calibrated and NOT ship-approved (#3252, plan 3.7). Twenty
  /// seconds is only the floor of the approved formula N = max(20 s, 3 x max(cold p99, warm
  /// p99)). Chunk 4 must replace or confirm it from at least 30 cold and 30 warm full moves on a
  /// notarized build before this ships; neither historical timings nor a passing unit test
  /// calibrate it.
  static let provisionalMoveWatchdogSeconds: TimeInterval = 20

  /// The one pre-flight run of this coordinator. A second call awaits the same run and returns
  /// its outcome, so a repeated call can never start the app while the first move can still
  /// quit it.
  private var preflightTask: Task<PreflightOutcome, Never>?

  /// The worker task of the most recent pre-flight move. Exposed so tests can await the SUBJECT's
  /// own completion after a watchdog expiry; production never reads it. It is never cancelled:
  /// cancellation is not what keeps a late result inert, the released authority is.
  private(set) var preflightWorker: Task<Void, Never>?

  /// The authority of the most recent pre-flight move, exposed for the same reason as
  /// `preflightWorker`: tests read its final state; production never does.
  private(set) var preflightAuthority: HandoffAuthority?

  init(
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
    makeAttemptID: @escaping @Sendable () -> String = { UUID().uuidString },
    chooseDestination: @escaping @MainActor (String) -> Destination = {
      ApplicationRelocationCoordinator.chooseDestination(appName: $0)
    },
    moveWatchdogSeconds: TimeInterval = ApplicationRelocationCoordinator
      .provisionalMoveWatchdogSeconds,
    watchdogSleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
      try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
    },
    destinationIsRunning: @escaping @MainActor (String, URL) -> Bool = {
      FileManagerApplicationMover.isRunning(bundleIdentifier: $0, at: $1)
    }
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
    self.chooseDestination = chooseDestination
    self.moveWatchdogSeconds = moveWatchdogSeconds
    self.watchdogSleep = watchdogSleep
    self.destinationIsRunning = destinationIsRunning
  }

  /// Location state for this launch, including the DEBUG-only forced state.
  private func detectState() -> ApplicationLocationState {
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
    return state
  }

  /// What this launch should do about the offer (plan 3.2). Gathers the value inputs for the
  /// pure `LaunchDecision.decide`; clears nothing.
  func launchDecision() -> LaunchDecision {
    LaunchDecision.decide(
      isRelaunchChild: env.relaunchAttemptID != nil, state: detectState(),
      lastDecline: suppression.lastDecline(), currentVersion: env.currentVersion, now: now())
  }

  /// The launch-state duties that outlive the offer (plan 3.6): (1) the relaunched child's
  /// health ack, its `completed` event and its unhealthy quit; (2) clearing a stale decline on
  /// every launch whose location does not block updates. It never shows an offer.
  func reportLaunchState() {
    reportLaunchState(state: detectState())
  }

  private func reportLaunchState(state: ApplicationLocationState) {
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
      let ackPublished = handshake.writeAck(
        attemptID: attemptID,
        resolvedPath: env.bundleURL.standardizedFileURL.path,
        healthy: healthy,
        stateLabel: state.ackStateLabel,
        bundleVersion: env.currentVersion)
      // Telemetry metadata is best-effort and must NEVER gate the health ack
      // above: an OLD parent launches us without it, and a missing label must
      // cost only the `completed` event, never the handshake itself.
      // THE RULE FOR THIS EVENT, enumerated once rather than patched per
      // instance (two review rounds found two members of the same class):
      // `completed` asserts "a usable DESTINATION copy was observed", so the
      // child emits it only when it has VERIFIED every part of that claim:
      //   1. it is healthy;
      //   2. it IS the copy the parent placed — Launch Services can route an
      //      open request to another registered copy, which would be healthy
      //      and would claim success for an attempt the parent fails as a
      //      path/version mismatch;
      //   3. its ack was actually published — a silent write failure means the
      //      parent times out and fails the attempt.
      // Any of these missing and the same attempt id carries both `completed`
      // and `failed`, corrupting the success rate this whole change exists to
      // produce.
      //
      // ACCEPTED RESIDUAL, stated rather than engineered around: the child
      // cannot know the parent's deadline, so a child that comes up healthy
      // just after the parent gave up still emits `completed` while the parent
      // emits `ackTimeout`. That pair is genuine information (the copy IS
      // usable, the handoff was not confirmed) and is reported separately in
      // the success-rate query rather than silently folded into either column.
      let isExpectedCopy =
        env.relaunchExpectedPath == env.bundleURL.standardizedFileURL.path
        && env.relaunchExpectedVersion == env.currentVersion
      if healthy, isExpectedCopy, ackPublished, let reason = env.relaunchReason,
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
      // branches are mutually exclusive within this child. A healthy late child
      // may coexist with a parent that already timed out and started normally.
      if !healthy { terminate() }
      return
    }

    // A healthy (non-blocking) launch clears any stale decline marker so a user who later
    // regresses is offered fresh. A blocked launch keeps its record.
    if !state.isUpdateBlocking { suppression.clear() }
  }

  // MARK: Cadence

  /// True when we may show the prompt: never declined, or the decline is stale
  /// (>7d) or from a different version. No permanent "don't ask again" — that
  /// would knowingly leave updates broken forever. The one cadence definition; its only
  /// production caller is `LaunchDecision.decide`.
  static func offerIsDue(
    lastDecline: (at: Date, version: String)?, currentVersion: String, now: Date
  ) -> Bool {
    guard let decline = lastDecline else { return true }
    if decline.version != currentVersion { return true }
    return now.timeIntervalSince(decline.at) >= declineCooldown
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
      .stripFailedAtDestination, .stripFailedAfterPlacement, .ackUnhealthyTranslocated,
      .ackUnhealthyOther, .installTimedOut, .unknown:
      // A copy that may be unclean is never offered for opening, whichever
      // route left it that way.
      return .nothingMoved(failure)
    }
  }

  // MARK: Pre-flight (#3252, plan 3.4)

  /// Shows the failure card `runPreflight` returned. The caller runs it only AFTER the app has
  /// started, on a later run-loop turn: the card is modal and its copy says the app keeps working.
  func presentFailure(_ presentation: RelocationFailurePresentation) {
    presenter.showFailure(presentation)
  }

  /// How one move attempt resolved. Resolved exactly once, by the worker or the watchdog,
  /// whichever releases the authority first.
  private enum MoveResolution: Sendable {
    case handedOff
    case failed(RelocationFailure, RelocationFailurePresentation, installResolution: String)
    case timedOut
  }

  /// What one stage sequence ended in. `abandoned` means the authority was no longer pending,
  /// so the stage did nothing further and the resolution belongs to someone else.
  private enum StageResult: Sendable {
    case handedOff
    case failed(RelocationFailure, RelocationFailurePresentation, installResolution: String)
    case abandoned
  }

  /// One-shot rendezvous: the first `resolve` wins and the others are ignored.
  @MainActor
  private final class MoveCompletion {
    private var value: MoveResolution?
    private var waiter: CheckedContinuation<MoveResolution, Never>?

    func resolve(_ resolution: MoveResolution) {
      guard value == nil else { return }
      value = resolution
      waiter?.resume(returning: resolution)
      waiter = nil
    }

    func wait() async -> MoveResolution {
      if let value { return value }
      return await withCheckedContinuation { waiter = $0 }
    }
  }

  /// Runs the offer for a launch that `LaunchDecision` returned `.offerFirst` for, before the
  /// app starts any work. The caller starts the app normally on `.continueNormally` and shows
  /// the returned card only AFTER that. Runs once per coordinator: a repeated or reentrant call
  /// awaits the first run and returns the same outcome, with no second offer and no second
  /// worker. A move that does not finish before the watchdog expires releases the authority and
  /// returns without waiting for the late worker.
  func runPreflight(state: ApplicationLocationState) async -> PreflightOutcome {
    if let task = preflightTask { return await task.value }
    let task = Task { @MainActor [self] in await executePreflight(state: state) }
    preflightTask = task
    return await task.value
  }

  private func executePreflight(state: ApplicationLocationState) async -> PreflightOutcome {
    guard let reason = state.reasonLabel else { return .continueNormally(failure: nil) }

    let destination = chooseDestination(env.bundleURL.lastPathComponent)
    telemetry.offered(reason: reason, destinationScope: destination.scope)

    switch await presenter.present() {
    case .notNow:
      suppression.recordDecline(at: now(), version: env.currentVersion)
      telemetry.declined(reason: reason)
      return .continueNormally(failure: nil)
    case .move:
      return await runMove(reason: reason, destination: destination)
    }
  }

  private func runMove(reason: String, destination: Destination) async -> PreflightOutcome {
    // Mint the id BEFORE `accepted` so the ingress event and every terminal event share one
    // join key. It used to be minted inside the relaunch path, so `accepted` carried none and
    // nothing could be joined to it, which is why four accepted attempts in 30 d have no known
    // outcome.
    let attemptID = makeAttemptID()
    telemetry.accepted(reason: reason, destinationScope: destination.scope, attemptID: attemptID)
    presenter.showProgress()

    let authority = HandoffAuthority()
    preflightAuthority = authority
    let completion = MoveCompletion()
    // The watchdog starts when Move is accepted, not while the person considers the offer.
    let worker = Task { @MainActor [self] in
      let result = await runMoveStages(
        authority: authority, reason: reason, destination: destination, attemptID: attemptID)
      switch result {
      case .handedOff:
        completion.resolve(.handedOff)
      case .failed(let failure, let presentation, let installResolution):
        if authority.release() {
          completion.resolve(
            .failed(failure, presentation, installResolution: installResolution))
        }
      case .abandoned:
        break
      }
    }
    preflightWorker = worker
    let watchdog = Task { @MainActor [self] in
      do { try await watchdogSleep(moveWatchdogSeconds) } catch { return }
      if authority.release() { completion.resolve(.timedOut) }
    }

    let resolution = await completion.wait()
    // Cleanup only. A cancelled sleep that already returned changes nothing, and the worker is
    // never cancelled: the released authority is what keeps a late result inert.
    watchdog.cancel()
    switch resolution {
    case .handedOff:
      return .handedOff
    case .failed(let failure, let presentation, let installResolution):
      presenter.dismissProgress()
      telemetry.failed(
        reason: reason, failureClass: failure.rawValue, attemptID: attemptID,
        installResolution: installResolution)
      return .continueNormally(failure: presentation)
    case .timedOut:
      presenter.dismissProgress()
      let failure = RelocationFailure.installTimedOut
      telemetry.failed(
        reason: reason, failureClass: failure.rawValue, attemptID: attemptID,
        installResolution: InstallResolution.TelemetryLabel.unresolved)
      return .continueNormally(
        failure: Self.presentation(for: failure, destination: destination.url))
    }
  }

  /// Install, then activate or relaunch. Every stage is entered only while the authority is
  /// pending and re-checks it after every suspension, so a late result does nothing: no launch,
  /// no activation, no termination, no card, no second terminal event. Terminal events other than
  /// the success ones belong to `runMove`.
  private func runMoveStages(
    authority: HandoffAuthority, reason: String, destination: Destination, attemptID: String
  ) async -> StageResult {
    guard authority.isPending else { return .abandoned }
    let result = await mover.install(
      source: env.bundleURL, destination: destination.url,
      expectedBundleIdentifier: env.bundleIdentifier, currentVersion: env.currentVersion)
    guard authority.isPending else { return .abandoned }

    switch result {
    case .failure(let failure):
      // The mover returns Result<InstallResolution, _>, so a failure carries no resolution to
      // read, but the failure itself can still identify the route (see
      // `impliedInstallResolution`).
      return .failed(
        failure, Self.presentation(for: failure, destination: destination.url),
        installResolution: failure.impliedInstallResolution)
    case .success(let resolution) where resolution.isExistingRunning:
      // A verified same-or-newer copy is already running: bring it to the front and terminate
      // this translocated duplicate. No new instance, no handshake (cloud Codex review #1490).
      return await activateStage(
        authority: authority, reason: reason, destination: destination, resolution: resolution,
        attemptID: attemptID)
    case .success(let resolution):
      return await relaunchStage(
        authority: authority, reason: reason, destination: destination, resolution: resolution,
        attemptID: attemptID)
    }
  }

  /// The good copy is already running: activate it, then terminate self. If it cannot be
  /// activated, keep the current process alive and report failure.
  private func activateStage(
    authority: HandoffAuthority, reason: String, destination: Destination,
    resolution: InstallResolution, attemptID: String
  ) async -> StageResult {
    guard authority.isPending else { return .abandoned }
    let activated = await relauncher.activateRunning(resolution.url)
    guard authority.isPending else { return .abandoned }
    guard activated else {
      return .failed(
        .relaunchRejected, Self.presentation(for: .relaunchRejected, destination: resolution.url),
        installResolution: resolution.telemetryLabel)
    }
    // The activated copy must still be running. External exit after this check cannot be
    // prevented; the check closes the window to the instructions below, which never suspend.
    guard destinationIsRunning(env.bundleIdentifier, resolution.url) else {
      return .failed(
        .relaunchRejected, Self.presentation(for: .relaunchRejected, destination: resolution.url),
        installResolution: resolution.telemetryLabel)
    }
    // No suspension from here to terminate(): commit, then the success events, then quit.
    guard authority.commit() else { return .abandoned }
    telemetry.relaunched(
      reason: reason, destinationScope: destination.scope, relaunchConfirmed: true,
      attemptID: attemptID, installResolution: resolution.telemetryLabel)
    // This route launches NO child, so a child-only `completed` would silently drop the whole
    // existing-running success path from the success rate.
    telemetry.completed(
      reason: reason, destinationScope: destination.scope, attemptID: attemptID,
      completionSource: "existing_running_activation")
    flushTelemetry()
    terminate()
    return .handedOff
  }

  /// Relaunch, then wait for the new instance's health ack BEFORE terminating the current (only
  /// known-good) process. NSWorkspace acceptance alone is not a sufficient handoff boundary (A1).
  private func relaunchStage(
    authority: HandoffAuthority, reason: String, destination: Destination,
    resolution: InstallResolution, attemptID: String
  ) async -> StageResult {
    let installedURL = resolution.url
    guard authority.isPending else { return .abandoned }
    let launched = await relauncher.relaunch(
      installedURL, attemptID: attemptID, reason: reason, destinationScope: destination.scope,
      expectedBundleVersion: resolution.bundleVersion)
    guard authority.isPending else { return .abandoned }
    guard launched else {
      return .failed(
        .relaunchRejected, Self.presentation(for: .relaunchRejected, destination: installedURL),
        installResolution: resolution.telemetryLabel)
    }

    // Expected version comes from the MOVER's resolution, never from env.currentVersion:
    // `.existingUsable` accepts a same-or-newer destination (#2006 §3.2).
    let outcome = await handshake.awaitAck(
      attemptID: attemptID, destination: installedURL,
      expectedBundleVersion: resolution.bundleVersion, timeout: handshakeTimeout)
    guard authority.isPending else { return .abandoned }
    guard outcome == .confirmed else {
      // The new copy never confirmed healthy at the destination. Keep the current process alive
      // rather than strand the user with no working app.
      let failure = outcome.failure
      return .failed(
        failure, Self.presentation(for: failure, destination: installedURL),
        installResolution: resolution.telemetryLabel)
    }

    // A healthy ack is a file the child wrote; the child may have exited since. Quit only while
    // the destination copy is still running. Exit after this check cannot be prevented.
    guard destinationIsRunning(env.bundleIdentifier, installedURL) else {
      return .failed(
        .relaunchRejected, Self.presentation(for: .relaunchRejected, destination: installedURL),
        installResolution: resolution.telemetryLabel)
    }
    // No suspension from here to terminate().
    guard authority.commit() else { return .abandoned }
    telemetry.relaunched(
      reason: reason, destinationScope: destination.scope, relaunchConfirmed: true,
      attemptID: attemptID, installResolution: resolution.telemetryLabel)
    // A5: best-effort, non-blocking flush; never delays the handoff.
    flushTelemetry()
    terminate()
    return .handedOff
  }
}
