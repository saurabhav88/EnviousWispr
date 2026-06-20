import EnviousWisprCore
import Foundation

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
    let clientProxy =
      connection.remoteObjectProxyWithErrorHandler { error in
        // XPC callback delivery failed — host may have crashed or disconnected.
        // Log but don't crash the service.
      } as? AudioServiceClientProtocol
    handler.clientProxy = clientProxy

    connection.exportedObject = handler

    // Crash-recovery limb (#1063 PR1): when the host (app) disconnects
    // mid-recording — e.g. an app crash — flush + finalize the spool best-effort
    // so its prefix carries an interrupted marker. The helper outlives the
    // disconnected client, so this typically drains; it is additive to the
    // writer's periodic durable flush and never a guaranteed zero tail.
    connection.invalidationHandler = { [weak handler] in
      handler?.flushRecoveryOnInvalidation()
    }

    connection.resume()
    return true
  }
}
