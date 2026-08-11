import AppKit
import EnviousWisprServices
import Foundation
import Security
import SwiftUI

// Issue #1451: production wiring for the App Translocation recovery limb.
// Pure policy + seam protocols live in ApplicationRelocationCoordinator.swift;
// every side-effecting implementation (UserDefaults, NSAlert, FileManager,
// NSWorkspace, the ack-file handshake, TelemetryService) lives here so the
// coordinator's logic stays unit-testable with fakes.

// MARK: - Suppression store

/// `UserDefaults`-backed "Not Now" memory. Missing keys mean "never declined"
/// (safe for every existing user). `@unchecked Sendable`: `UserDefaults` is
/// documented thread-safe; the struct holds only that reference.
public struct UserDefaultsRelocationSuppressionStore: RelocationSuppressionStore,
  @unchecked Sendable
{
  private let defaults: UserDefaults
  static let lastDeclinedAtKey = "ew.relocation.lastDeclinedAt"
  static let lastDeclinedVersionKey = "ew.relocation.lastDeclinedBundleVersion"

  public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

  public func lastDecline() -> (at: Date, version: String)? {
    guard
      let at = defaults.object(forKey: Self.lastDeclinedAtKey) as? Date,
      let version = defaults.string(forKey: Self.lastDeclinedVersionKey)
    else { return nil }
    return (at, version)
  }

  public func recordDecline(at: Date, version: String) {
    defaults.set(at, forKey: Self.lastDeclinedAtKey)
    defaults.set(version, forKey: Self.lastDeclinedVersionKey)
  }

  public func clear() {
    defaults.removeObject(forKey: Self.lastDeclinedAtKey)
    defaults.removeObject(forKey: Self.lastDeclinedVersionKey)
  }
}

// MARK: - Presenter (centered card)

/// A borderless, self-sizing panel that can become key so its SwiftUI buttons
/// receive clicks. Native rounding + shadow come from `.titled` +
/// `fullSizeContentView` with the title bar hidden.
private final class RelocationCardPanel: NSPanel {
  override var canBecomeKey: Bool { true }
}

/// Shared centered card chrome: app icon on top, centered title + body, then a
/// vertical stack of actions. Replaces the stock left-aligned `NSAlert` layout
/// (#1451 design polish — founder 2026-07-10). All copy is dash-free.
private struct RelocationCard<Actions: View>: View {
  let title: String
  let message: String
  var showsSpinner: Bool = false
  @ViewBuilder var actions: () -> Actions

  var body: some View {
    VStack(spacing: 18) {
      Image(nsImage: NSApp.applicationIconImage ?? NSImage())
        .resizable().aspectRatio(contentMode: .fit)
        .frame(width: 80, height: 80)
      Text(title)
        .font(.system(size: 24, weight: .bold))
        .multilineTextAlignment(.center)
      Text(message)
        .font(.system(size: 17))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      if showsSpinner {
        ProgressView().controlSize(.regular).padding(.top, 4)
      }
      VStack(spacing: 10) { actions() }
        .padding(.top, 10)
    }
    .padding(28)
    .frame(width: 400)
  }
}

/// Centered-card prompt + progress + failure surfaces for the relocation flow.
@MainActor
public final class CenteredRelocationPresenter: RelocationPresenting {
  private var progressPanel: NSPanel?

  /// Brand accent (#7c3aed) — the primary action's fill.
  private static let accent = Color(red: 124.0 / 255, green: 58.0 / 255, blue: 237.0 / 255)
  private static let moveResponse = NSApplication.ModalResponse(rawValue: 1001)
  private static let notNowResponse = NSApplication.ModalResponse(rawValue: 1002)

  public init() {}

  /// Builds a chromeless, self-sizing, centered card panel around a SwiftUI view.
  private func makeCardPanel<Content: View>(_ content: Content) -> NSPanel {
    let panel = RelocationCardPanel(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 220),
      styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.standardWindowButton(.closeButton)?.isHidden = true
    panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
    panel.standardWindowButton(.zoomButton)?.isHidden = true
    panel.isMovableByWindowBackground = true
    panel.isReleasedWhenClosed = false
    panel.level = .modalPanel
    let host = NSHostingView(rootView: content)
    panel.contentView = host
    panel.setContentSize(host.fittingSize)
    panel.center()
    return panel
  }

  public func present() async -> RelocationChoice {
    let card = RelocationCard(
      title: "Finish setting up EnviousWispr",
      message:
        "EnviousWispr is running from a temporary location, so it cannot receive updates. "
        + "EnviousWispr can fix this and reopen automatically."
    ) {
      VStack(spacing: 10) {
        Button {
          NSApp.stopModal(withCode: Self.moveResponse)
        } label: {
          Text("Move EnviousWispr")
            .font(.system(size: 17, weight: .semibold))
            .frame(maxWidth: .infinity).padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent).controlSize(.large).tint(Self.accent)
        Button {
          NSApp.stopModal(withCode: Self.notNowResponse)
        } label: {
          Text("Not Now")
            .font(.system(size: 17, weight: .medium))
            .frame(maxWidth: .infinity).padding(.vertical, 4)
        }
        .buttonStyle(.bordered).controlSize(.large)
      }
    }
    let panel = makeCardPanel(card)
    NSApp.activate(ignoringOtherApps: true)
    panel.makeKeyAndOrderFront(nil)
    let response = NSApp.runModal(for: panel)
    panel.orderOut(nil)
    return response == Self.moveResponse ? .move : .notNow
  }

  public func showProgress() {
    let card = RelocationCard(
      title: "Moving EnviousWispr",
      message: "Installing to your Applications folder. EnviousWispr will reopen automatically.",
      showsSpinner: true
    ) { EmptyView() }
    let panel = makeCardPanel(card)
    panel.makeKeyAndOrderFront(nil)
    progressPanel = panel
  }

  public func dismissProgress() {
    progressPanel?.orderOut(nil)
    progressPanel = nil
  }

  public func showFailure(_ presentation: RelocationFailurePresentation) {
    dismissProgress()
    let (title, message) = Self.failureCopy(presentation)
    // Show in Finder exists ONLY on Message B, and its target comes from the
    // presentation rather than being recomputed here — the coordinator owns the
    // destination (#2006 §3b/§3c). Message A structurally cannot carry one.
    var revealURL: URL?
    if case .installedNotConfirmed(_, let destination) = presentation {
      revealURL = destination
    }
    let card = RelocationCard(title: title, message: message) {
      VStack(spacing: 10) {
        if let revealURL {
          Button {
            NSWorkspace.shared.activateFileViewerSelecting([revealURL])
            NSApp.stopModal()
          } label: {
            Text("Show in Finder")
              .font(.system(size: 17, weight: .semibold))
              .frame(maxWidth: .infinity).padding(.vertical, 4)
          }
          .buttonStyle(.borderedProminent).controlSize(.large).tint(Self.accent)
          Button {
            NSApp.stopModal()
          } label: {
            Text("OK")
              .font(.system(size: 17, weight: .medium))
              .frame(maxWidth: .infinity).padding(.vertical, 4)
          }
          .buttonStyle(.bordered).controlSize(.large)
        } else {
          Button {
            NSApp.stopModal()
          } label: {
            Text("OK")
              .font(.system(size: 17, weight: .semibold))
              .frame(maxWidth: .infinity).padding(.vertical, 4)
          }
          .buttonStyle(.borderedProminent).controlSize(.large).tint(Self.accent)
        }
      }
    }
    let panel = makeCardPanel(card)
    NSApp.activate(ignoringOtherApps: true)
    panel.makeKeyAndOrderFront(nil)
    NSApp.runModal(for: panel)
    panel.orderOut(nil)
  }

  /// TWO message families, not one per failure class (founder 2026-08-10,
  /// #2006 §3.3). Three pre-placement sentences survive as overrides inside
  /// Message A because each names a precondition the user must clear before any
  /// manual drag can succeed — collapsing those would REMOVE information.
  /// Package-internal (not `private`) so the mapping is exhaustively testable.
  static func failureCopy(_ presentation: RelocationFailurePresentation) -> (String, String) {
    // Message B: a verified copy IS at the destination; only handoff failed.
    if case .installedNotConfirmed = presentation {
      return (
        "EnviousWispr is now in your Applications folder.",
        "You can quit this copy and use the one in Applications."
      )
    }
    // Message A, with the three surviving precondition overrides.
    switch presentation.failure {
    case .diskFull:
      return (
        "Not enough space to move EnviousWispr.",
        "Nothing was changed. Free up some space, then reopen EnviousWispr to try again."
      )
    case .destinationRunning:
      return (
        "Another copy of EnviousWispr is already open.",
        "Nothing was changed. Quit the other copy, then reopen EnviousWispr to finish moving it."
      )
    case .destinationConflict:
      return (
        "A different app is already in that Applications spot.",
        "Nothing was changed. EnviousWispr is still working. You can move it yourself in Finder anytime."
      )
    // Generic Message A. Deliberately does NOT promise a manual drag always
    // works: this arm also covers a full disk and a non-writable Applications
    // folder, which dragging cannot overcome either.
    case .destinationCreation, .stagingCopy, .stagedBundleInvalid, .signatureInvalid,
      .stripFailedBeforePlacement, .stripFailedAtDestination, .ackUnhealthyTranslocated,
      .ackUnhealthyOther, .ackPathMismatch, .ackVersionMismatch, .ackMalformed, .ackTimeout,
      .relaunchRejected, .unknown:
      return (
        "We couldn't move EnviousWispr automatically.",
        "Drag EnviousWispr to your Applications folder in Finder. EnviousWispr keeps working in the meantime."
      )
    }
  }
}

// MARK: - Mover

/// The safe verdict for an app already sitting at the destination.
public enum ExistingDestinationDecision: Equatable, Sendable {
  /// Same-or-newer, verified copy, NOT running → open it fresh, never downgrade
  /// or overwrite.
  case openExisting
  /// Same-or-newer, verified copy that is ALREADY running → activate it, never
  /// spawn a duplicate (cloud Codex review #1490).
  case activateRunning
  /// Older copy currently running → refuse; never downgrade to it and a running
  /// bundle cannot be safely overwritten (Codex r2 P1).
  case refuseRunningOlder
  /// Older copy, not running → stage + atomic replace.
  case replace
  /// Different app, un-inspectable, or any copy (older or newer) that fails the
  /// signature gate → never delete, overwrite, or launch it.
  case conflict
}

/// Copies the running bundle into the destination and resolves any existing
/// copy safely: same-or-newer/running → open it (`.existingUsable`); older →
/// atomic `replaceItemAt` after staging + signature validation on the
/// destination volume (never Trash-first); absent → move staged into place.
public struct FileManagerApplicationMover: ApplicationMoving {
  /// Our Developer ID Team ID (scripts/build-release-dmg.sh TEAM_ID). The staged
  /// copy must satisfy `anchor apple generic` + this signing identity before it
  /// replaces anything.
  static let teamID = "9UT54V24XG"

  public init() {}

  /// Pure conflict-resolution matrix for a bundle already at the destination.
  /// Extracted so the routing that a Codex r2 P1 slipped through (downgrading to
  /// an older running copy) is unit-tested independently of the filesystem.
  static func decideExistingDestination(
    existingBundleIdentifier: String?, expectedBundleIdentifier: String,
    existingVersion: String, currentVersion: String,
    isRunning: Bool, signatureValid: Bool
  ) -> ExistingDestinationDecision {
    guard existingBundleIdentifier == expectedBundleIdentifier else { return .conflict }
    // Never act on a bundle we cannot verify as genuinely ours — not launch it
    // (open-existing) and not destroy it (replace). A plist id/version is not
    // proof of identity; an unsigned, corrupted, or impostor bundle squatting
    // our path and id must be left untouched (Codex r1 P2 + r3 P2). The rare
    // corrupted-real-install case falls to a Finder-move escape.
    guard signatureValid else { return .conflict }
    let cmp = UpdateAvailabilityService.compareVersions(existingVersion, currentVersion)
    if cmp >= 0 {
      // Same-or-newer, verified: activate it if already running (never
      // duplicate — cloud #1490), otherwise open it fresh. Never downgrade or
      // overwrite.
      return isRunning ? .activateRunning : .openExisting
    }
    // Older, verified: replace when safe, refuse when it is running (a running
    // bundle cannot be overwritten and must not be downgraded to).
    return isRunning ? .refuseRunningOlder : .replace
  }

  public func install(
    source: URL, destination: URL,
    expectedBundleIdentifier: String, currentVersion: String
  ) async -> Result<InstallResolution, RelocationFailure> {
    let fm = FileManager.default
    let destParent = destination.deletingLastPathComponent()

    // Ensure the Applications parent exists (creates ~/Applications for the
    // user-domain fallback). Never requires admin.
    if !fm.fileExists(atPath: destParent.path) {
      do { try fm.createDirectory(at: destParent, withIntermediateDirectories: true) } catch {
        return .failure(.destinationCreation)
      }
    }

    // Resolve an existing bundle at the destination BEFORE copying. The pure
    // decision lives in `decideExistingDestination` (unit-tested matrix); this
    // block only gathers the observable facts and acts on the verdict.
    if fm.fileExists(atPath: destination.path) {
      let existing = Bundle(url: destination)
      let existingVersion =
        existing?.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
      let isRunning = Self.isRunning(bundleIdentifier: expectedBundleIdentifier, at: destination)
      // Signature is only load-bearing for the open-existing verdict; compute it
      // once here so the decision function stays pure.
      let signatureValid = Self.hasValidSignature(
        destination, expectedBundleIdentifier: expectedBundleIdentifier)
      switch Self.decideExistingDestination(
        existingBundleIdentifier: existing?.bundleIdentifier,
        expectedBundleIdentifier: expectedBundleIdentifier,
        existingVersion: existingVersion, currentVersion: currentVersion,
        isRunning: isRunning, signatureValid: signatureValid)
      {
      case .openExisting:
        // Same-or-newer, verified, not running: open it fresh, do not downgrade
        // or overwrite. Strip BEFORE launching it: a copy left behind by a
        // previous failed attempt is still quarantined, which is precisely the
        // repeat path person A was stuck in — without this, attempt N+1 fails
        // identically to attempt N (#2006). Verified above, so stripping is a
        // trust action taken only on a bundle proven ours.
        guard Self.stripQuarantine(at: destination) else {
          return .failure(.stripFailedAtDestination)
        }
        return .success(.existingUsable(destination, bundleVersion: existingVersion))
      case .activateRunning:
        // Same-or-newer, verified, already running: activate it, never spawn a
        // duplicate (cloud Codex review #1490).
        return .success(.existingRunning(destination, bundleVersion: existingVersion))
      case .refuseRunningOlder:
        // Older + running: never downgrade to it, and a running bundle cannot be
        // safely overwritten. Keep the current app alive (Codex r2 P1).
        return .failure(.destinationRunning)
      case .conflict:
        // Different app, un-inspectable, or a same-or-newer copy that fails the
        // signature gate — never delete, overwrite, or launch it (Codex r1 P2).
        return .failure(.destinationConflict)
      case .replace:
        break  // Older + not running → stage + atomic replace below.
      }
    }

    // Stage on the SAME volume as the destination so the swap can be atomic.
    let staging = destParent.appendingPathComponent(
      ".EnviousWispr.installing-\(UUID().uuidString).app")
    defer { try? fm.removeItem(at: staging) }
    do {
      try fm.copyItem(at: source, to: staging)
    } catch {
      let ns = error as NSError
      if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError {
        return .failure(.diskFull)
      }
      return .failure(.stagingCopy)
    }

    // Structural validation.
    guard
      Self.isStructurallyValid(
        staging, expectedBundleIdentifier: expectedBundleIdentifier, currentVersion: currentVersion)
    else { return .failure(.stagedBundleInvalid) }

    // A4: code-signature validity + our signing identity, before overwrite.
    guard Self.hasValidSignature(staging, expectedBundleIdentifier: expectedBundleIdentifier)
    else { return .failure(.signatureInvalid) }

    // Strip quarantine while the bundle is still at its UUID-named staging
    // path, so the copy only ever appears under the real destination name
    // already clean. Order is load-bearing — verify, THEN strip, THEN place:
    // stripping is a trust action, and doing it before validation could leave
    // an untrusted staged bundle dequarantined if cleanup were interrupted.
    // Removing this one xattr does not alter code-signed content (#2006).
    guard Self.stripQuarantine(at: staging) else {
      return .failure(.stripFailedBeforePlacement)
    }

    // Place it: atomic replace when a destination exists, else move in.
    // `.usingNewMetadataOnly` says explicitly: the bundle we just verified and
    // stripped is the source of truth, not the item it replaces. Measured on
    // APFS 2026-08-10, quarantine is NOT inherited either way — so this is not
    // fixing an observed bug, it is removing the need to rely on a metadata
    // rule we do not control (cloud review P1).
    do {
      if fm.fileExists(atPath: destination.path) {
        _ = try fm.replaceItemAt(
          destination, withItemAt: staging, backupItemName: nil,
          options: .usingNewMetadataOnly)
      } else {
        try fm.moveItem(at: staging, to: destination)
      }
    } catch {
      return .failure(.unknown)
    }

    // VERIFY THE END STATE, do not assume it. Everything above establishes
    // that the bundle was clean at its staging path; this establishes that it
    // is clean WHERE IT WILL ACTUALLY LAUNCH FROM, which is the only property
    // that matters. Idempotent and cheap: the probe-first path returns
    // immediately for every already-clean item.
    guard Self.stripQuarantine(at: destination) else {
      return .failure(.stripFailedAtDestination)
    }
    // `isStructurallyValid` above asserted the staged bundle's CFBundleVersion
    // equals `currentVersion`, so this IS the version the mover verified.
    return .success(.installed(destination, bundleVersion: currentVersion))
  }

  static func isRunning(bundleIdentifier: String, at url: URL) -> Bool {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
      .contains { $0.bundleURL?.standardizedFileURL == url.standardizedFileURL }
  }

  static func isStructurallyValid(
    _ url: URL, expectedBundleIdentifier: String, currentVersion: String
  ) -> Bool {
    guard let bundle = Bundle(url: url),
      bundle.bundleIdentifier == expectedBundleIdentifier,
      bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String == currentVersion,
      FileManager.default.isExecutableFile(
        atPath: url.appendingPathComponent("Contents/MacOS/EnviousWispr").path)
    else { return false }
    return true
  }

  static func hasValidSignature(_ url: URL, expectedBundleIdentifier: String) -> Bool {
    // The identifier is interpolated into a requirement string, so a value
    // carrying a quote or backslash could change the requirement's meaning.
    // Ours cannot, but a requirement built from unvalidated input is a defect
    // shape regardless of reachability; refuse before building it rather than
    // relying on SecRequirementCreateWithString to fail closed (#2006).
    guard !expectedBundleIdentifier.isEmpty,
      !expectedBundleIdentifier.contains("\""),
      !expectedBundleIdentifier.contains("\\")
    else { return false }
    var staticCode: SecStaticCode?
    guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
      let code = staticCode
    else { return false }
    // Validity anchored to Apple's chain, our Developer ID Team ID, AND this
    // exact product. `isStructurallyValid` already asserts the identifier from
    // the Info.plist a statement earlier; binding it into the requirement makes
    // identity part of the CRYPTOGRAPHIC assertion instead, so the two checks
    // cannot pass against different states of the bundle (#2006).
    let requirementText =
      """
      anchor apple generic \
      and identifier "\(expectedBundleIdentifier)" \
      and certificate leaf[subject.OU] = "\(teamID)"
      """ as CFString
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(requirementText, [], &requirement) == errSecSuccess,
      let req = requirement
    else { return false }
    return SecStaticCodeCheckValidity(code, [], req) == errSecSuccess
  }

  // MARK: - Quarantine

  /// Removes `com.apple.quarantine` from `root` and every descendant.
  ///
  /// THE fix for #2006. A translocated bundle carries the attribute on its
  /// randomized mount (measured: `00c3;00000000;Safari;`), `FileManager` copies
  /// preserve it, and macOS then translocates the placed copy AGAIN under a new
  /// UUID — so the move "succeeds" and the relaunched copy is still trapped.
  /// Mirrors Sparkle's `SUFileManager.releaseItemFromQuarantineAtRootURL`
  /// (`SUFileManager.m:22,86-164`) in shape, with one deliberate difference:
  /// Sparkle treats aggregate failure as advisory because it is polishing an
  /// already-installed app, whereas for us stripping IS the transaction, so any
  /// failure is fatal to the relocation.
  ///
  /// Removes ONLY this attribute — never a blanket `xattr -c` — and never
  /// follows symlinks, so a link inside the bundle cannot be used to clear the
  /// attribute on a file outside it.
  static func stripQuarantine(at root: URL) -> Bool {
    let attr = "com.apple.quarantine"

    func remove(_ url: URL) -> Bool {
      let ok = url.withUnsafeFileSystemRepresentation { path -> Bool in
        guard let path else { return false }
        // PROBE BEFORE REMOVING. `removexattr` on an item owned by root or
        // another admin returns EPERM even when the attribute is ABSENT, so
        // removing unconditionally would fail a perfectly clean destination
        // copy and send its user Message A instead of opening it — a
        // regression on the already-supported existing-destination path
        // (whole-diff review r3). Reading an xattr needs no write permission,
        // so the probe succeeds exactly where the removal cannot.
        // XATTR_NOFOLLOW throughout: act on the link itself, never its target.
        if getxattr(path, attr, nil, 0, 0, XATTR_NOFOLLOW) < 0 {
          // Absent is success; any other probe error means we cannot tell.
          return errno == ENOATTR
        }
        // Present: it must actually come off. The ENOATTR retry covers the
        // benign race where something else removed it after the probe.
        return removexattr(path, attr, XATTR_NOFOLLOW) == 0 || errno == ENOATTR
      }
      return ok
    }

    guard remove(root) else { return false }

    // A subtree we could not read is NOT a clean bundle. Record the first
    // traversal error and stop; returning success after silently skipping an
    // inaccessible directory would report a stripped bundle that still carries
    // the attribute, which is the exact false-negative this change exists to
    // remove.
    var traversalFailed = false
    guard
      let walker = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: nil,
        // No options: the target IS an .app package, so package descendants
        // must be visited, and hidden files inside a bundle carry the
        // attribute too.
        options: [],
        errorHandler: { _, _ in
          traversalFailed = true
          return false  // stop enumerating
        })
    else { return false }

    for case let item as URL in walker {
      guard remove(item) else { return false }
    }
    return !traversalFailed
  }
}

// MARK: - Relauncher

/// Launches the installed copy as a NEW instance carrying the relaunch marker +
/// attempt ID. Both instances run briefly; the original terminates only after
/// the handshake confirms (A1).
public struct NSWorkspaceRelocationRelauncher: RelocationRelaunching {
  public init() {}

  public func relaunch(
    _ installedURL: URL, attemptID: String, reason: String, destinationScope: String,
    expectedBundleVersion: String
  ) async -> Bool {
    let config = NSWorkspace.OpenConfiguration()
    config.createsNewApplicationInstance = true
    config.activates = true
    // Reason + scope let the CHILD emit its own `completed` event. A child that
    // receives neither (old parent) still writes its health ack and simply
    // emits nothing (#2006 §9).
    config.environment = [
      "EW_RELOCATION_RELAUNCH": "1",
      "EW_RELOCATION_ATTEMPT_ID": attemptID,
      "EW_RELOCATION_REASON": reason,
      "EW_RELOCATION_DESTINATION_SCOPE": destinationScope,
      // The child validates these before claiming completion, so a different
      // registered copy cannot report success for our attempt (review P2).
      "EW_RELOCATION_EXPECTED_PATH": installedURL.standardizedFileURL.path,
      "EW_RELOCATION_EXPECTED_VERSION": expectedBundleVersion,
    ]
    return await withCheckedContinuation { continuation in
      NSWorkspace.shared.openApplication(at: installedURL, configuration: config) { app, error in
        continuation.resume(returning: error == nil && app != nil)
      }
    }
  }

  public func activateRunning(_ url: URL) async -> Bool {
    // Bring the already-running instance at this exact URL to the front; never
    // spawn a new one (cloud Codex review #1490).
    let target = url.standardizedFileURL
    let running = NSWorkspace.shared.runningApplications.first {
      $0.bundleURL?.standardizedFileURL == target
    }
    guard let app = running else { return false }
    return app.activate()
  }
}

// MARK: - Handshake (ack file)

/// The relaunched child writes a per-attempt ack file; the original polls for
/// it (signal = file appearance) up to a bounded deadline. Keyed by attempt ID
/// so a stale ack from a prior attempt can never confirm a new one, and it only
/// confirms when the child reports healthy AT THE EXACT destination path (A2).
public struct FileRelocationHandshake: RelocationHandshaking {
  private let directory: URL
  private let pollInterval: TimeInterval

  private struct Ack: Codable {
    let resolvedPath: String
    let healthy: Bool
    /// Both optional ON THE WIRE. An ack written by an OLDER child carries
    /// neither. `decodeIfPresent` semantics come free from the optionals; an
    /// absent value must read as UNKNOWN, never as a mismatch, or every
    /// cross-version handoff breaks (#2006 §4).
    let stateLabel: String?
    let bundleVersion: String?
  }

  public init(
    directory: URL = FileRelocationHandshake.defaultDirectory, pollInterval: TimeInterval = 0.15
  ) {
    self.directory = directory
    self.pollInterval = pollInterval
  }

  public static var defaultDirectory: URL {
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
      .appendingPathComponent("Library/Application Support", isDirectory: true)
    return base.appendingPathComponent("EnviousWispr", isDirectory: true)
  }

  private func ackURL(_ attemptID: String) -> URL {
    directory.appendingPathComponent("relocation-ack-\(attemptID).json")
  }

  @discardableResult
  public func writeAck(
    attemptID: String, resolvedPath: String, healthy: Bool, stateLabel: String?,
    bundleVersion: String?
  ) -> Bool {
    let fm = FileManager.default
    try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    guard
      let data = try? JSONEncoder().encode(
        Ack(
          resolvedPath: resolvedPath, healthy: healthy, stateLabel: stateLabel,
          bundleVersion: bundleVersion))
    else { return false }
    // Report publication rather than swallowing it: an unwritable Application
    // Support or a full disk means the parent never sees this and times out,
    // so the child must not go on to claim success (review P2).
    do {
      try data.write(to: ackURL(attemptID), options: .atomic)
      return true
    } catch {
      return false
    }
  }

  public func awaitAck(
    attemptID: String, destination: URL, expectedBundleVersion: String, timeout: TimeInterval
  ) async -> RelocationAckOutcome {
    let url = ackURL(attemptID)
    let deadline = Date().addingTimeInterval(timeout)
    defer { try? FileManager.default.removeItem(at: url) }
    while Date() < deadline {
      if let data = try? Data(contentsOf: url) {
        guard let ack = try? JSONDecoder().decode(Ack.self, from: data) else {
          // A file exists but will not decode. Do not keep polling a corpse.
          return .malformed
        }
        // Order is load-bearing: health, then exact path, then version. A
        // version check must never pre-empt the two conditions that already
        // work (#2006 §3.2).
        guard ack.healthy else { return .unhealthy(stateLabel: ack.stateLabel) }
        guard ack.resolvedPath == destination.standardizedFileURL.path else {
          return .pathMismatch
        }
        // Compare ONLY when the child supplied a version. Absent means an old
        // child, which must still confirm.
        if let actual = ack.bundleVersion, actual != expectedBundleVersion {
          return .versionMismatch
        }
        return .confirmed
      }
      try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
    }
    return .timedOut
  }
}

// MARK: - Telemetry sink

/// Forwards to `TelemetryService` (same actor) with bounded, low-cardinality
/// properties. Pre-update recovery stage — deliberately NOT `update.install_*`,
/// preserving #1447's producer-stage separation.
@MainActor
public struct TelemetryServiceRelocationSink: RelocationTelemetrySink {
  public init() {}
  public func offered(reason: String, destinationScope: String) {
    TelemetryService.shared.updateRelocationOffered(
      reason: reason, destinationScope: destinationScope)
  }
  public func accepted(reason: String, destinationScope: String, attemptID: String) {
    TelemetryService.shared.updateRelocationAccepted(
      reason: reason, destinationScope: destinationScope, attemptID: attemptID)
  }
  public func declined(reason: String) {
    TelemetryService.shared.updateRelocationDeclined(reason: reason)
  }
  public func failed(
    reason: String, failureClass: String, attemptID: String, installResolution: String
  ) {
    TelemetryService.shared.updateRelocationFailed(
      reason: reason, failureClass: failureClass, attemptID: attemptID,
      installResolution: installResolution)
  }
  public func relaunched(
    reason: String, destinationScope: String, relaunchConfirmed: Bool, attemptID: String,
    installResolution: String
  ) {
    TelemetryService.shared.updateRelocationRelaunched(
      reason: reason, destinationScope: destinationScope, relaunchConfirmed: relaunchConfirmed,
      attemptID: attemptID, installResolution: installResolution)
  }
  public func completed(
    reason: String, destinationScope: String, attemptID: String, completionSource: String
  ) {
    TelemetryService.shared.updateRelocationCompleted(
      reason: reason, destinationScope: destinationScope, attemptID: attemptID,
      completionSource: completionSource)
  }
}

// MARK: - Live factory

extension ApplicationRelocationCoordinator {
  /// Production wiring. `AppLifecycleCoordinator` constructs this once via
  /// `WisprBootstrapper` and calls `evaluateAndOfferIfNeeded()` on launch.
  @MainActor
  public static func live() -> ApplicationRelocationCoordinator {
    ApplicationRelocationCoordinator(
      env: .live(),
      detector: ApplicationLocationDetector(),
      suppression: UserDefaultsRelocationSuppressionStore(),
      presenter: CenteredRelocationPresenter(),
      mover: FileManagerApplicationMover(),
      relauncher: NSWorkspaceRelocationRelauncher(),
      handshake: FileRelocationHandshake(),
      telemetry: TelemetryServiceRelocationSink(),
      terminate: { NSApp.terminate(nil) },
      flushTelemetry: { TelemetryService.shared.flushTelemetry(reason: .relocation) }
    )
  }
}
