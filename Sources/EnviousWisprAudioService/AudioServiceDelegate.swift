import Foundation
import EnviousWisprCore

final class AudioServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: AudioServiceProtocol.self)

        // Set up the reverse interface so the service can call back to the host.
        connection.remoteObjectInterface = NSXPCInterface(with: AudioServiceClientProtocol.self)

        let handler = AudioServiceHandler()
        handler.connection = connection
        connection.exportedObject = handler
        connection.resume()
        return true
    }
}
