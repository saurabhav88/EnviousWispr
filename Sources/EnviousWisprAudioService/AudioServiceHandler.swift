import Foundation
import AVFoundation
import EnviousWisprCore

final class AudioServiceHandler: NSObject, AudioServiceProtocol {
    /// The XPC connection back to the host — set by AudioServiceDelegate after accept.
    weak var connection: NSXPCConnection?

    func ping(reply: @escaping (String) -> Void) {
        reply("pong")
    }

    func checkMicPermission(reply: @escaping (Int, String) -> Void) {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        let name: String
        switch status {
        case .notDetermined: name = "notDetermined"
        case .restricted:    name = "restricted"
        case .denied:        name = "denied"
        case .authorized:    name = "authorized"
        @unknown default:    name = "unknown(\(status.rawValue))"
        }
        reply(status.rawValue, name)
    }
}
