import Foundation
import EnviousWisprCore

final class ASRServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: ASRServiceProtocol.self)
        connection.remoteObjectInterface = NSXPCInterface(with: ASRServiceClientProtocol.self)

        let handler = ASRServiceHandler()
        handler.connection = connection

        connection.exportedObject = handler
        connection.resume()
        return true
    }
}
