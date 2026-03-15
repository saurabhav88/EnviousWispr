import Foundation
import EnviousWisprCore

final class AudioServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: AudioServiceProtocol.self)
        connection.remoteObjectInterface = NSXPCInterface(with: AudioServiceClientProtocol.self)

        let handler = AudioServiceHandler()
        handler.connection = connection

        // Resolve client proxy for service→host callbacks.
        // XPC remote object proxies are thread-safe — safe to call from xpcSendQueue.
        let clientProxy = connection.remoteObjectProxyWithErrorHandler { error in
            // XPC callback delivery failed — host may have crashed or disconnected.
            // Log but don't crash the service.
        } as? AudioServiceClientProtocol
        handler.clientProxy = clientProxy

        connection.exportedObject = handler
        connection.resume()
        return true
    }
}
