import ApplicationServices
import EnviousWisprCore
@preconcurrency import AVFoundation

/// Manages microphone and accessibility permission checks.
@MainActor
@Observable
public final class PermissionsService {
    public private(set) var microphoneStatus: AVAuthorizationStatus = .notDetermined
    public private(set) var accessibilityGranted: Bool = false

    /// Whether the user has explicitly dismissed the accessibility warning banner.
    /// Stored property so @Observable tracks changes and SwiftUI re-renders.
    /// Synced to UserDefaults in didSet so it survives restarts.
    public private(set) var accessibilityWarningDismissed: Bool = UserDefaults.standard.bool(forKey: "accessibilityWarningDismissed") {
        didSet { UserDefaults.standard.set(accessibilityWarningDismissed, forKey: "accessibilityWarningDismissed") }
    }

    /// True when the accessibility warning should be shown in the UI.
    public var shouldShowAccessibilityWarning: Bool {
        !accessibilityGranted && !accessibilityWarningDismissed
    }

    public init() {
        microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        accessibilityGranted = AXIsProcessTrusted()
    }

    /// Request microphone access. Returns true if granted.
    public func requestMicrophoneAccess() async -> Bool {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        return granted
    }

    /// Whether microphone permission has been granted.
    public var hasMicrophonePermission: Bool {
        microphoneStatus == .authorized
    }

    /// Prompt the user to grant Accessibility permission in System Settings.
    /// Only called from explicit user action (e.g., Settings button). Never called automatically.
    /// Returns true if already granted; otherwise opens the System Settings prompt.
    public func requestAccessibilityAccess() -> Bool {
        let options = [
            "AXTrustedCheckOptionPrompt" as CFString: true as CFBoolean
        ] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        accessibilityGranted = trusted
        return trusted
    }

    /// Re-check Accessibility permission using `AXIsProcessTrusted()` (no prompt).
    /// Detects revocation transitions (granted → revoked) and re-arms the warning.
    public func refreshAccessibilityStatus() {
        let wasGranted = accessibilityGranted
        let nowGranted = AXIsProcessTrusted()
        accessibilityGranted = nowGranted

        // Revocation detected: re-arm the warning so it shows again.
        if wasGranted && !nowGranted {
            resetAccessibilityWarningDismissal()
        }
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
}
