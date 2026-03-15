import Foundation

/// XPC protocol: commands from host app to audio service.
@objc public protocol AudioServiceProtocol {
    /// Connection health check.
    func ping(reply: @escaping (String) -> Void)

    /// Report current microphone authorization status as seen by the XPC service process.
    func checkMicPermission(reply: @escaping (Int, String) -> Void)
}

/// XPC protocol: callbacks from audio service to host app.
@objc public protocol AudioServiceClientProtocol {
    /// Heartbeat / audio level update.
    func audioLevelUpdated(_ level: Float)
}
