@preconcurrency import AVFoundation
import ApplicationServices

/// Manages microphone and accessibility permission checks.
@MainActor
@Observable
final class PermissionsService {
    private(set) var microphoneStatus: AVAuthorizationStatus = .notDetermined
    private(set) var accessibilityGranted: Bool = false
    private var pollTimer: Timer?

    init() {
        microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        accessibilityGranted = AXIsProcessTrusted()
        startAccessibilityPolling()
    }

    /// Poll AXIsProcessTrusted() periodically so the UI updates after the user
    /// toggles the setting in System Settings.
    private func startAccessibilityPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.accessibilityGranted = AXIsProcessTrusted()
            }
        }
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

    /// Whether accessibility permission is granted (for paste-to-active-app).
    var hasAccessibilityPermission: Bool {
        accessibilityGranted
    }

    /// Prompt the user for accessibility permission.
    nonisolated func promptAccessibilityPermission() {
        // Use string literal to avoid Swift 6 concurrency issue with the C global
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
