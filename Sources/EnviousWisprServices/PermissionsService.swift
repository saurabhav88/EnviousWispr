@preconcurrency import AVFoundation
import AppKit
import ApplicationServices
import EnviousWisprCore

/// Manages microphone and accessibility permission checks.
@MainActor
@Observable
public final class PermissionsService {
  public private(set) var microphoneStatus: AVAuthorizationStatus = .notDetermined
  public private(set) var accessibilityGranted: Bool = false

  /// Called when either permission's status changes — set by AppDelegate/MenuBarController for
  /// icon and menu updates. #2549: renamed from `onAccessibilityChange`; the monitor below now
  /// observes both permissions, so a single accessibility-only name would be misleading.
  public var onPermissionChange: (() -> Void)?

  private var permissionMonitorTask: Task<Void, Never>?

  /// Whether the user has explicitly dismissed the accessibility warning banner.
  /// Stored property so @Observable tracks changes and SwiftUI re-renders.
  /// Synced to UserDefaults in didSet so it survives restarts.
  public private(set) var accessibilityWarningDismissed: Bool = UserDefaults.standard.bool(
    forKey: "accessibilityWarningDismissed")
  {
    didSet {
      UserDefaults.standard.set(
        accessibilityWarningDismissed, forKey: "accessibilityWarningDismissed")
    }
  }

  /// True when the accessibility warning should be shown in the UI.
  public var shouldShowAccessibilityWarning: Bool {
    !accessibilityGranted && !accessibilityWarningDismissed
  }

  /// Injected so tests can drive a grant/revoke flip deterministically; defaults
  /// to the live no-prompt system check in production.
  private let accessibilityReader: () -> Bool

  /// Injected mirror of `accessibilityReader` for the microphone status, so the
  /// start-path error router (#1558) is testable; defaults to the live
  /// no-prompt system check.
  private let microphoneReader: () -> AVAuthorizationStatus

  /// #2549: injected so tests can observe/intercept the System Settings
  /// deep-link without a real window opening; defaults to the real
  /// `NSWorkspace` call.
  private let openMicrophoneSettings: @MainActor (URL) -> Void

  public init(
    accessibilityReader: @escaping () -> Bool = { AXIsProcessTrusted() },
    microphoneReader: @escaping () -> AVAuthorizationStatus = {
      AVCaptureDevice.authorizationStatus(for: .audio)
    },
    openMicrophoneSettings: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
  ) {
    self.accessibilityReader = accessibilityReader
    self.microphoneReader = microphoneReader
    self.openMicrophoneSettings = openMicrophoneSettings
    microphoneStatus = microphoneReader()
    accessibilityGranted = accessibilityReader()
  }

  /// #1558: live microphone-denied check for the start-path error router. A
  /// prewarm failure while permission is denied or restricted must map to the
  /// actionable "Microphone access is off." notice, not the generic retry.
  /// Reads live (not the cached snapshot) so a mid-session revoke is honored.
  public var microphonePermissionIsDenied: Bool {
    switch microphoneReader() {
    case .denied, .restricted: return true
    default: return false
    }
  }

  /// Request microphone access. Returns true if granted.
  public func requestMicrophoneAccess() async -> Bool {
    let granted = await AVCaptureDevice.requestAccess(for: .audio)
    microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    TelemetryService.shared.permissionStatus(
      permission: "microphone", status: granted ? "granted" : "denied", context: "request")
    return granted
  }

  /// #2549: request microphone access when not yet asked, or send the user to
  /// System Settings when access is already denied. Apple's `requestAccess`
  /// API only ever shows the system dialog once, from the "not yet asked"
  /// state — after an explicit deny it returns `false` immediately with no
  /// dialog, every time. Single shared owner for both Settings → Permissions
  /// and onboarding, so the branch is not copied at each call site.
  public func requestMicrophoneAccessOrOpenSettings() async {
    if microphonePermissionIsDenied {
      if let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
      {
        openMicrophoneSettings(url)
      }
    } else {
      _ = await requestMicrophoneAccess()
    }
  }

  /// Whether microphone permission has been granted.
  public var hasMicrophonePermission: Bool {
    microphoneStatus == .authorized
  }

  /// Microphone authorization as a stable, content-free telemetry string.
  /// Telemetry Bible Phase 3 (#1172): fed into the launch `settings.snapshot`.
  public var microphoneStatusString: String {
    switch microphoneStatus {
    case .authorized: return "authorized"
    case .denied: return "denied"
    case .restricted: return "restricted"
    case .notDetermined: return "not_determined"
    @unknown default: return "unknown"
    }
  }

  /// Prompt the user to grant Accessibility permission in System Settings.
  /// Only called from explicit user action (e.g., Settings button). Never called automatically.
  /// Returns true if already granted; otherwise opens the System Settings prompt.
  public func requestAccessibilityAccess() -> Bool {
    let options =
      [
        "AXTrustedCheckOptionPrompt" as CFString: true as CFBoolean
      ] as CFDictionary
    let trusted = AXIsProcessTrustedWithOptions(options)
    accessibilityGranted = trusted
    TelemetryService.shared.permissionStatus(
      permission: "accessibility", status: trusted ? "granted" : "denied", context: "request")
    return trusted
  }

  /// Live Accessibility read for a telemetry SEAM that must observe the RESOLVED
  /// value, not the lagging `accessibilityGranted` cache (Telemetry Bible Phase 7,
  /// cloud Codex review r3). A pure `AXIsProcessTrusted()` read (no prompt) with NO
  /// side effects — unlike `refreshAccessibilityStatus()`, it does not mutate the
  /// cache, re-arm the warning, or emit a `permission.status` flip event. Use it at
  /// emit points (e.g. the onboarding-abandon posture) where the cache may still be
  /// false in the ~2 s window after a grant but before the next poll/launch/pre-record
  /// refresh. Injectable via the same `accessibilityReader` the init/refresh use.
  public var accessibilityGrantedLive: Bool { accessibilityReader() }

  /// Re-check Accessibility permission using `AXIsProcessTrusted()` (no prompt).
  /// Detects revocation transitions (granted → revoked) and re-arms the warning.
  public func refreshAccessibilityStatus() {
    let wasGranted = accessibilityGranted
    let nowGranted = accessibilityReader()
    accessibilityGranted = nowGranted

    guard wasGranted != nowGranted else { return }

    // Revocation detected: re-arm the warning so it shows again.
    if wasGranted && !nowGranted {
      resetAccessibilityWarningDismissal()
    }

    // Telemetry Bible Phase 3 (#1172): record the grant/revoke flip wherever the
    // app already re-checks (background poll / onboarding / launch / pre-record).
    // Limb: fire-and-forget metadata only, never blocks the heart path.
    TelemetryService.shared.permissionStatus(
      permission: "accessibility",
      status: nowGranted ? "granted" : "denied",
      context: "changed")
  }

  /// Mark the accessibility warning as dismissed by the user.
  public func dismissAccessibilityWarning() {
    accessibilityWarningDismissed = true
  }

  /// Re-arm the accessibility warning (e.g., after permission is revoked).
  public func resetAccessibilityWarningDismissal() {
    accessibilityWarningDismissed = false
  }

  /// Whether Accessibility permission has been granted.
  public var hasAccessibilityPermission: Bool {
    accessibilityGranted
  }

  /// Check Accessibility permission on launch (no prompt, no polling side-effects).
  /// If denied, reset warning dismissal (binary may have been rebuilt, invalidating TCC grant).
  public func refreshOnLaunch() {
    refreshAccessibilityStatus()
    if !accessibilityGranted {
      resetAccessibilityWarningDismissal()
    }
  }

  /// #2549: true while EITHER permission still needs the monitor watching it.
  /// Shared by `startMonitoring()` and `restartMonitoringIfNeeded()` so they
  /// can never disagree about when the monitor is needed.
  ///
  /// **Round-1 cloud-review finding: this must read "not yet AUTHORIZED", not
  /// "denied".** `.notDetermined` — the ordinary state before the user has
  /// ever been asked — is neither granted nor denied, so a denied-only check
  /// never starts the monitor for it. A user whose very first system prompt
  /// is a DENY is then watched by nothing: the monitor never ran, so nothing
  /// notices the transition into denied, and nothing notices a later grant
  /// via Open Settings either.
  private var permissionMonitoringStillNeeded: Bool {
    !accessibilityGranted || microphoneReader() != .authorized
  }

  /// Start smart polling for Accessibility AND Microphone permission (#2549:
  /// generalized from Accessibility-only).
  /// Polls every TimingConstants.accessibilityPollIntervalSec seconds, but ONLY
  /// while at least one permission is outstanding. Exits once BOTH are granted.
  public func startMonitoring() {
    guard permissionMonitorTask == nil || permissionMonitorTask?.isCancelled == true else {
      return
    }
    guard permissionMonitoringStillNeeded else { return }

    var lastAccessibilityGranted = accessibilityGranted
    var lastMicrophoneAuthorized = microphoneReader() == .authorized

    permissionMonitorTask = Task { [weak self] in
      while true {
        try? await Task.sleep(
          nanoseconds: UInt64(TimingConstants.accessibilityPollIntervalSec * 1_000_000_000))
        guard let self, !Task.isCancelled else { return }
        self.refreshAccessibilityStatus()
        // #2549: read the mic status ONCE this tick and reuse the single
        // snapshot for the assignment, the authorized-state comparison, and
        // the exit decision — never a second, independent
        // `microphoneReader()` read in the same tick, which would be a
        // separate OS call that could in principle disagree.
        //
        // Round-1 cloud-review finding: track AUTHORIZED, not denied. Denied
        // is what the WARNING shows (`microphonePermissionIsDenied`), but the
        // MONITOR must also keep running through `.notDetermined` — the
        // ordinary pre-prompt state — so a first-prompt deny is still caught,
        // and a later grant via Open Settings is still caught too.
        let microphoneStatusNow = self.microphoneReader()
        self.microphoneStatus = microphoneStatusNow
        let microphoneAuthorizedNow = microphoneStatusNow == .authorized

        if self.accessibilityGranted != lastAccessibilityGranted
          || microphoneAuthorizedNow != lastMicrophoneAuthorized
        {
          lastAccessibilityGranted = self.accessibilityGranted
          lastMicrophoneAuthorized = microphoneAuthorizedNow
          self.onPermissionChange?()
        }

        if self.accessibilityGranted && microphoneAuthorizedNow {
          self.permissionMonitorTask = nil
          return
        }
      }
    }
  }

  /// Restart monitoring if not running and either permission is still missing.
  public func restartMonitoringIfNeeded() {
    let taskDone = permissionMonitorTask == nil || permissionMonitorTask?.isCancelled == true
    guard taskDone && permissionMonitoringStillNeeded else { return }
    startMonitoring()
  }
}
