import ApplicationServices
@preconcurrency import AVFoundation

/// Manages microphone and accessibility permission checks.
@MainActor
@Observable
final class PermissionsService {
    private(set) var microphoneStatus: AVAuthorizationStatus = .notDetermined
    private(set) var accessibilityGranted: Bool = false

    init() {
        microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        accessibilityGranted = AXIsProcessTrusted()
    }

    /// Request microphone access. Returns true if granted.
    func requestMicrophoneAccess() async -> Bool {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        return granted
    }

    /// Whether microphone permission has been granted.
    var hasMicrophonePermission: Bool {
        microphoneStatus == .authorized
    }

    /// Prompt the user to grant Accessibility permission in System Settings.
    /// Returns true if already granted; otherwise opens the System Settings prompt.
    func requestAccessibilityAccess() -> Bool {
        let options = [
            "AXTrustedCheckOptionPrompt" as CFString: true as CFBoolean
        ] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        accessibilityGranted = trusted
        return trusted
    }

    /// Re-check Accessibility permission (e.g., after user returns from System Settings).
    func refreshAccessibilityStatus() {
        accessibilityGranted = AXIsProcessTrusted()
    }

    /// Whether Accessibility permission has been granted.
    var hasAccessibilityPermission: Bool {
        accessibilityGranted
    }
}
