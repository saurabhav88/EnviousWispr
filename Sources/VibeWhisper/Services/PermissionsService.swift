@preconcurrency import AVFoundation
import ApplicationServices

/// Manages microphone and accessibility permission checks.
@MainActor
@Observable
final class PermissionsService {
    private(set) var microphoneStatus: AVAuthorizationStatus = .notDetermined

    init() {
        microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
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
        AXIsProcessTrusted()
    }

    /// Prompt the user for accessibility permission.
    nonisolated func promptAccessibilityPermission() {
        // Use string literal to avoid Swift 6 concurrency issue with the C global
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
