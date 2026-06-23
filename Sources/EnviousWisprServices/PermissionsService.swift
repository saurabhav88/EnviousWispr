@preconcurrency import AVFoundation
import ApplicationServices
import EnviousWisprCore

/// Manages microphone and accessibility permission checks.
@MainActor
@Observable
public final class PermissionsService {
  public private(set) var microphoneStatus: AVAuthorizationStatus = .notDetermined
  public private(set) var accessibilityGranted: Bool = false

  /// Called when accessibility permission status changes — set by AppDelegate for icon updates.
  public var onAccessibilityChange: (() -> Void)?

  private var accessibilityMonitorTask: Task<Void, Never>?

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

  public init(accessibilityReader: @escaping () -> Bool = { AXIsProcessTrusted() }) {
    self.accessibilityReader = accessibilityReader
    microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    accessibilityGranted = accessibilityReader()
  }

  /// Request microphone access. Returns true if granted.
  public func requestMicrophoneAccess() async -> Bool {
    let granted = await AVCaptureDevice.requestAccess(for: .audio)
    microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    TelemetryService.shared.permissionStatus(
      permission: "microphone", status: granted ? "granted" : "denied", context: "request")
    return granted
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

  /// Start smart polling for Accessibility permission.
  /// Polls every TimingConstants.accessibilityPollIntervalSec seconds, but ONLY
  /// while accessibilityGranted == false. Once granted, loop exits.
  public func startMonitoring() {
    guard accessibilityMonitorTask == nil || accessibilityMonitorTask?.isCancelled == true else {
      return
    }
    guard !accessibilityGranted else { return }

    accessibilityMonitorTask = Task { [weak self] in
      while true {
        try? await Task.sleep(
          nanoseconds: UInt64(TimingConstants.accessibilityPollIntervalSec * 1_000_000_000))
        guard let self, !Task.isCancelled else { return }
        self.refreshAccessibilityStatus()
        if self.accessibilityGranted {
          self.onAccessibilityChange?()
          self.accessibilityMonitorTask = nil
          return
        }
      }
    }
  }

  /// Restart monitoring if not running and permission is missing.
  public func restartMonitoringIfNeeded() {
    let taskDone = accessibilityMonitorTask == nil || accessibilityMonitorTask?.isCancelled == true
    guard taskDone && !accessibilityGranted else { return }
    startMonitoring()
  }
}
