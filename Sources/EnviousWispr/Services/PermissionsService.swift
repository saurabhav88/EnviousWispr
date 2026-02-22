@preconcurrency import AVFoundation

/// Manages microphone permission checks.
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
}
